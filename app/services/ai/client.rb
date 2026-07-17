# frozen_string_literal: true

require "net/http"
require "uri"

module Ai
  class Client
    class ApiError < StandardError; end

    def initialize(config = nil)
      @config = config || Rails.application.config_for(:emanator).dig(:ai)
      @endpoint = @config[:endpoint]
      @model = @config[:content_model]
      @api_key = ENV["VENICE_API_KEY"] || ENV["OPENAI_API_KEY"]
    end

    def chat(messages:, temperature: 0.3, max_tokens: 1000)
      response = http_client.post(
        "#{@endpoint}/chat/completions",
        json: {
          model: @model,
          messages: messages,
          temperature: temperature,
          max_tokens: max_tokens
        }
      )

      handle_response(response)
    end

    def chat_stream(messages:, temperature: 0.3, max_tokens: 1000, &block)
      uri = URI.parse("#{@endpoint}/chat/completions")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = 300
      http.open_timeout = 30

      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@api_key}" if @api_key.present?

      request.body = {
        model: @model,
        messages: messages,
        temperature: temperature,
        max_tokens: max_tokens,
        stream: true
      }.to_json

      buffer = ""

      http.request(request) do |response|
        unless response.code == "200"
          error_body = response.body rescue "Unknown error"
          raise ApiError, "API request failed (#{response.code}): #{error_body}"
        end

        response.read_body do |chunk|
          buffer += chunk

          while (event_end = buffer.index("\n\n"))
            event_data = buffer.slice!(0, event_end + 2)

            data_lines = event_data.lines.select { |l| l.start_with?("data:") }
            data = data_lines.map { |l| l.sub(/^data:\s?/, "").chomp }.join("\n")

            next if data.empty? || data == "[DONE]"

            begin
              parsed = JSON.parse(data)
              content = parsed.dig("choices", 0, "delta", "content")
              yield content if !content.nil? && block_given?
            rescue JSON::ParserError
            end
          end
        end
      end
    end

    private

    def http_client
      headers = { "Content-Type" => "application/json" }
      headers["Authorization"] = "Bearer #{@api_key}" if @api_key.present?

      @http_client ||= HTTPX.plugin(:retries)
        .with(
          headers: headers,
          timeout: {
            connect_timeout: 30,
            read_timeout: 300,
            write_timeout: 60,
            request_timeout: 300
          }
        )
    end

    def handle_response(response)
      if response.is_a?(HTTPX::ErrorResponse)
        raise ApiError, "Connection failed: #{response.error.message}"
      end

      unless response.status == 200
        error_body = begin
          JSON.parse(response.body.to_s)
        rescue
          { "error" => response.body.to_s }
        end
        raise ApiError, "API request failed (#{response.status}): #{error_body}"
      end

      data = JSON.parse(response.body.to_s)
      content = data.dig("choices", 0, "message", "content")

      raise ApiError, "No content in response" if content.blank?

      content
    end
  end
end
