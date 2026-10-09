# frozen_string_literal: true

module NostrBilling
  # Thin HTTP client for the billing API (see the nostr-billing README). Only the
  # standard library, so the apps take no new dependency. Every method returns
  # the parsed JSON body as a Hash with string keys, or raises one of the errors
  # in errors.rb.
  class Client
    LOOPBACK_HOSTS = %w[127.0.0.1 ::1 [::1] localhost].freeze

    def initialize(url:, token:, open_timeout: 2, read_timeout: 4)
      @base = URI.parse(url.to_s.chomp("/"))
      unless @base.is_a?(URI::HTTPS) || (@base.is_a?(URI::HTTP) && LOOPBACK_HOSTS.include?(@base.host))
        raise ConfigError, "BILLING_API_URL must be https, or http on a loopback address"
      end

      @token = token
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def entitlement(npub)
      request(:get, "/v1/entitlement/#{URI.encode_www_form_component(npub)}")
    end

    def start_trial(npub, product)
      request(:post, "/v1/trials", { npub: npub, product: product })
    end

    def consume(npub, product, kind:, units: 1, key: nil)
      request(:post, "/v1/consume", { npub: npub, product: product, kind: kind, units: units, key: key }.compact)
    end

    def create_charge(npub, plan:, sats: nil, redirect_url: nil)
      request(:post, "/v1/charges", { npub: npub, plan: plan, sats: sats, redirect_url: redirect_url }.compact)
    end

    def charge(id)
      request(:get, "/v1/charges/#{URI.encode_www_form_component(id)}")
    end

    def plans
      request(:get, "/v1/plans")
    end

    private

    def request(method, path, body = nil)
      uri = URI.parse("#{@base}#{path}")
      req = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Accept"] = "application/json"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: @open_timeout, read_timeout: @read_timeout,
                                 write_timeout: @read_timeout) { |http| http.request(req) }
      handle(response)
    rescue Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError, EOFError => e
      raise Unavailable, "billing unreachable: #{e.class}: #{e.message}"
    end

    def handle(response)
      status = response.code.to_i
      data = parse(response.body)
      message = data["error"] || "billing answered #{status}"

      case status
      when 200..299 then data
      when 409 then raise Conflict, message
      when 400, 404 then raise BadRequest.new(message, status: status)
      when 401, 403 then raise ConfigError, "billing rejected the API key (#{status})"
      when 429, 500..599 then raise Unavailable, message
      else raise Unavailable, "billing answered #{status}"
      end
    end

    def parse(body)
      value = JSON.parse(body.to_s.empty? ? "{}" : body)
      value.is_a?(Hash) ? value : {}
    rescue JSON::ParserError
      {}
    end
  end
end
