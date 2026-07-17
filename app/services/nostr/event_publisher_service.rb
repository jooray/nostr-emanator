# frozen_string_literal: true

module Nostr
  class EventPublisherService
    PUBLISH_TIMEOUT = 10

    def initialize
      @config = Rails.application.config_for(:emanator)
      @default_relays = @config.dig("nostr", "relays") || []
    end

    # Publish a pre-signed event to relays
    # Returns hash of { relay_url => :ok/:error }
    def publish(signed_event, relays: [])
      all_relays = (relays + @default_relays).uniq
      results = {}

      all_relays.each do |relay_url|
        begin
          result = publish_to_relay(relay_url, signed_event)
          results[relay_url] = result
          Rails.logger.info("Published to #{relay_url}: #{result}")
        rescue StandardError => e
          results[relay_url] = :error
          Rails.logger.warn("Failed to publish to #{relay_url}: #{e.message}")
        end
      end

      results
    end

    private

    def publish_to_relay(relay_url, signed_event)
      uri = URI.parse(relay_url)
      socket = create_websocket(uri)
      return :error unless socket

      # Send EVENT message
      message = ["EVENT", signed_event]
      socket.write(frame_text(message.to_json))

      # Wait for OK response
      deadline = Time.now + PUBLISH_TIMEOUT

      while Time.now < deadline
        ready = WebsocketConnection.readable_now?(socket) || IO.select([socket], nil, nil, 1)
        next unless ready

        data = read_websocket_frame(socket)
        next unless data

        begin
          parsed = JSON.parse(data)
          if parsed[0] == "OK"
            socket.close rescue nil
            return parsed[2] ? :ok : :rejected
          elsif parsed[0] == "NOTICE"
            Rails.logger.warn("Relay notice from #{relay_url}: #{parsed[1]}")
          end
        rescue JSON::ParserError
          next
        end
      end

      socket.close rescue nil
      :timeout
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
