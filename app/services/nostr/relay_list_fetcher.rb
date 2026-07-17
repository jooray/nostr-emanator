# frozen_string_literal: true

module Nostr
  class RelayListFetcher
    TIMEOUT = 5

    def initialize
      @config = Rails.application.config_for(:emanator)
      @relays = @config.dig("nostr", "relays") || ["wss://relay.damus.io"]
    end

    # Fetch kind 10002 (NIP-65) relay list for a pubkey
    # Returns array of write relay URLs
    def fetch_write_relays(pubkey_hex)
      return [] if pubkey_hex.blank?

      @relays.each do |relay_url|
        begin
          event = fetch_relay_list_event(relay_url, pubkey_hex)
          if event
            return parse_write_relays(event)
          end
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch relay list from #{relay_url}: #{e.message}")
        end
      end

      []
    end

    private

    def fetch_relay_list_event(relay_url, pubkey_hex)
      uri = URI.parse(relay_url)
      socket = create_websocket(uri)
      return nil unless socket

      sub_id = SecureRandom.hex(4)
      req = ["REQ", sub_id, { "kinds" => [10002], "authors" => [pubkey_hex], "limit" => 1 }]
      socket.write(frame_text(req.to_json))

      deadline = Time.now + TIMEOUT
      relay_event = nil

      while Time.now < deadline
        ready = WebsocketConnection.readable_now?(socket) || IO.select([socket], nil, nil, 0.5)
        next unless ready

        data = read_websocket_frame(socket)
        break unless data

        begin
          parsed = JSON.parse(data)
          if parsed[0] == "EVENT" && parsed[2] && parsed[2]["kind"] == 10002
            relay_event = parsed[2]
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

      relay_event
    end

    def parse_write_relays(event)
      return [] unless event && event["tags"]

      write_relays = []
      event["tags"].each do |tag|
        next unless tag[0] == "r" && tag[1].present?

        relay_url = tag[1]
        marker = tag[2] # "read", "write", or nil (both)

        if marker.nil? || marker == "write"
          write_relays << relay_url
        end
      end

      write_relays
    end

    # Reuse WebSocket helpers from ProfileFetcher pattern
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
    rescue StandardError
      nil
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
      length = socket.read(2).unpack1("n") if length == 126
      length = socket.read(8).unpack1("Q>") if length == 127
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
