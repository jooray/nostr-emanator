# frozen_string_literal: true

require "json"
require "socket"
require "openssl"
require "base64"
require "securerandom"

module Nostr
  class ProfileFetcher
    TIMEOUT = 5

    def initialize(additional_relays: [])
      @config = Rails.application.config_for(:emanator)
      global_relays = @config.dig("nostr", "relays") || ["wss://relay.damus.io", "wss://nos.lol"]
      @relays = (global_relays + Array(additional_relays)).map { |r| r.chomp("/") }.uniq
    end

    def fetch(pubkey_hex)
      return nil if pubkey_hex.blank?

      @relays.each do |relay_url|
        begin
          event = fetch_from_relay(relay_url, pubkey_hex)
          if event
            profile = parse_profile(event)
            return profile if profile
          end
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch profile from #{relay_url}: #{e.message}")
        end
      end

      nil
    end

    # Fetch profiles for multiple pubkeys in a single batch (parallel relays)
    def fetch_batch(pubkey_hexes)
      pubkey_hexes = Array(pubkey_hexes).compact.uniq
      return {} if pubkey_hexes.empty?

      filter = { "kinds" => [0], "authors" => pubkey_hexes }

      # Query all relays in parallel
      threads = @relays.map do |relay_url|
        Thread.new do
          begin
            fetch_events_from_relay(relay_url, filter)
          rescue StandardError => e
            Rails.logger.warn("Failed to batch fetch profiles from #{relay_url}: #{e.message}")
            []
          end
        end
      end

      all_events = threads.flat_map(&:value)

      # Dedupe by pubkey, keep most recent event per pubkey
      latest_by_pubkey = {}
      all_events.each do |event|
        pk = event["pubkey"]
        if latest_by_pubkey[pk].nil? || event["created_at"].to_i > latest_by_pubkey[pk]["created_at"].to_i
          latest_by_pubkey[pk] = event
        end
      end

      # Parse profiles
      result = {}
      latest_by_pubkey.each do |pk, event|
        profile = parse_profile(event)
        result[pk] = profile if profile
      end
      result
    end

    private

    # Fetch multiple events from a relay (used by fetch_batch)
    def fetch_events_from_relay(relay_url, filter)
      uri = URI.parse(relay_url)
      socket = create_websocket(uri)
      return [] unless socket

      sub_id = SecureRandom.hex(4)
      req = ["REQ", sub_id, filter]
      socket.write(frame_text(req.to_json))

      events = []
      deadline = Time.now + TIMEOUT

      while Time.now < deadline
        ready = WebsocketConnection.readable_now?(socket) || IO.select([socket], nil, nil, 0.5)
        next unless ready

        data = read_websocket_frame(socket)
        break unless data

        begin
          parsed = JSON.parse(data)
          case parsed[0]
          when "EVENT"
            events << parsed[2] if parsed[2]
          when "EOSE"
            break
          end
        rescue JSON::ParserError
          next
        end
      end

      socket.write(frame_text(["CLOSE", sub_id].to_json)) rescue nil
      socket.close rescue nil

      events
    end

    def fetch_from_relay(relay_url, pubkey_hex)
      uri = URI.parse(relay_url)
      socket = create_websocket(uri)
      return nil unless socket

      sub_id = SecureRandom.hex(4)
      req = ["REQ", sub_id, { "kinds" => [0], "authors" => [pubkey_hex], "limit" => 1 }]
      socket.write(frame_text(req.to_json))

      deadline = Time.now + TIMEOUT
      profile_event = nil

      while Time.now < deadline
        ready = WebsocketConnection.readable_now?(socket) || IO.select([socket], nil, nil, 0.5)
        next unless ready

        data = read_websocket_frame(socket)
        break unless data

        begin
          parsed = JSON.parse(data)
          if parsed[0] == "EVENT" && parsed[2] && parsed[2]["kind"] == 0
            profile_event = parsed[2]
            break
          elsif parsed[0] == "EOSE"
            break
          end
        rescue JSON::ParserError
          next
        end
      end

      socket.write(frame_text(["CLOSE", sub_id].to_json)) rescue nil
      socket.close rescue nil

      profile_event
    end

    def parse_profile(event)
      return nil unless event && event["content"]

      profile_data = JSON.parse(event["content"])

      {
        display_name: profile_data["display_name"] || profile_data["displayName"] || profile_data["name"],
        username: profile_data["name"] || profile_data["username"],
        about: profile_data["about"],
        picture: profile_data["picture"]
      }
    rescue JSON::ParserError
      nil
    end

    def create_websocket(uri)
      host = uri.host
      port = uri.port || (uri.scheme == "wss" ? 443 : 80)

      tcp_socket = Socket.tcp(host, port, connect_timeout: 5)
      tcp_socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

      socket = if uri.scheme == "wss"
        ctx = OpenSSL::SSL::SSLContext.new
        ssl_socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, ctx)
        ssl_socket.hostname = host
        ssl_socket.connect
        ssl_socket
      else
        tcp_socket
      end

      key = Base64.strict_encode64(SecureRandom.random_bytes(16))
      path = uri.path.empty? ? "/" : uri.path
      request = ["GET #{path} HTTP/1.1", "Host: #{host}", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: #{key}", "Sec-WebSocket-Version: 13", "", ""].join("\r\n")
      socket.write(request)

      response = ""
      while (line = socket.gets)
        response += line
        break if line == "\r\n"
      end

      return nil unless response.include?("101")
      socket
    end

    def frame_text(data)
      bytes = data.bytes
      frame = [0x81]
      if bytes.length < 126
        frame << (0x80 | bytes.length)
      elsif bytes.length < 65536
        frame << (0x80 | 126) << (bytes.length >> 8) << (bytes.length & 0xFF)
      else
        frame << (0x80 | 127)
        8.times { |i| frame << ((bytes.length >> (56 - i * 8)) & 0xFF) }
      end
      mask = 4.times.map { rand(256) }
      frame.concat(mask)
      bytes.each_with_index { |b, i| frame << (b ^ mask[i % 4]) }
      frame.pack("C*")
    end

    def read_websocket_frame(socket)
      first_byte = socket.read(1)&.unpack1("C")
      return nil unless first_byte
      second_byte = socket.read(1)&.unpack1("C")
      return nil unless second_byte
      masked = (second_byte & 0x80) != 0
      length = second_byte & 0x7F
      if length == 126
        length = socket.read(2).unpack1("n")
      elsif length == 127
        length = socket.read(8).unpack1("Q>")
      end
      mask = masked ? socket.read(4).bytes : nil
      payload = socket.read(length)
      return nil unless payload
      if masked
        payload = payload.bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }.pack("C*")
      end
      (+payload).force_encoding("UTF-8")
    rescue StandardError
      nil
    end
  end
end
