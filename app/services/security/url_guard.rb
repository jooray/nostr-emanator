# frozen_string_literal: true

require "resolv"
require "ipaddr"

module Security
  # Guards outbound connections against SSRF.
  #
  # Several URLs in this app come from places we do not control: the per-account
  # Blossom media server (user input), NIP-65 relay lists (fetched from relays)
  # and per-user custom relays. All of them are handed to the server, which then
  # connects to them from inside our network. UrlGuard is the single choke point
  # that decides whether such a URL may be contacted.
  #
  # Checks: scheme allowlist, no credentials/fragments, resolvable host, and
  # every resolved address must be a public unicast address (no loopback,
  # private, link-local — which includes the cloud metadata endpoint — CGNAT,
  # multicast or otherwise reserved range).
  #
  # This is a check-at-use-time guard, not a pinned-socket implementation: a DNS
  # rebind between validation and connect is still theoretically possible. It
  # closes the practical attack (pointing a setting at an internal host) without
  # rewriting the HTTP/WebSocket stacks.
  module UrlGuard
    class UnsafeUrlError < StandardError; end

    BLOCKED_RANGES = [
      # IPv4
      "0.0.0.0/8",        # this network
      "10.0.0.0/8",       # private
      "100.64.0.0/10",    # CGNAT
      "127.0.0.0/8",      # loopback
      "169.254.0.0/16",   # link-local (incl. 169.254.169.254 metadata)
      "172.16.0.0/12",    # private
      "192.0.0.0/24",     # IETF protocol assignments
      "192.0.2.0/24",     # TEST-NET-1
      "192.88.99.0/24",   # 6to4 relay anycast
      "192.168.0.0/16",   # private
      "198.18.0.0/15",    # benchmarking
      "198.51.100.0/24",  # TEST-NET-2
      "203.0.113.0/24",   # TEST-NET-3
      "224.0.0.0/4",      # multicast
      "240.0.0.0/4",      # reserved
      # IPv6
      "::/128",           # unspecified
      "::1/128",          # loopback
      "::ffff:0:0/96",    # IPv4-mapped
      "64:ff9b::/96",     # IPv4/IPv6 translation
      "100::/64",         # discard-only
      "2001:db8::/32",    # documentation
      "fc00::/7",         # unique local
      "fe80::/10",        # link-local
      "ff00::/8"          # multicast
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    module_function

    # Returns the parsed URI, or raises UnsafeUrlError with a message safe to
    # show the user.
    def validate!(url, schemes:)
      uri = parse(url, schemes)

      return uri if private_networks_allowed?

      addresses = resolve(uri.host)
      addresses.each do |address|
        if blocked?(address)
          raise UnsafeUrlError, "#{uri.host} resolves to a non-public address (#{address}) and cannot be used"
        end
      end

      uri
    end

    def safe?(url, schemes:)
      validate!(url, schemes: schemes)
      true
    rescue UnsafeUrlError
      false
    end

    # Convenience wrappers for the two kinds of URL this app deals with.
    def validate_http!(url)
      validate!(url, schemes: http_schemes)
    end

    def validate_relay!(url)
      validate!(url, schemes: relay_schemes)
    end

    def safe_relay?(url)
      safe?(url, schemes: relay_schemes)
    end

    # Plaintext ws:// and http:// are only tolerated where private networks are
    # tolerated (development), because they are how local relays are usually run.
    def http_schemes
      private_networks_allowed? ? %w[https http] : %w[https]
    end

    def relay_schemes
      private_networks_allowed? ? %w[wss ws] : %w[wss]
    end

    def private_networks_allowed?
      setting = Rails.application.config.x.allow_private_network_urls
      setting.nil? ? !Rails.env.production? : setting
    end

    def parse(url, schemes)
      raise UnsafeUrlError, "URL is blank" if url.blank?

      uri = URI.parse(url.to_s.strip)
      unless schemes.include?(uri.scheme)
        raise UnsafeUrlError, "URL must use #{schemes.map { |s| "#{s}://" }.join(" or ")}"
      end
      raise UnsafeUrlError, "URL must include a host" if uri.host.blank?
      raise UnsafeUrlError, "URL must not contain credentials" if uri.userinfo.present?

      uri
    rescue URI::InvalidURIError
      raise UnsafeUrlError, "URL is not valid"
    end

    def resolve(host)
      # A literal IP needs no DNS lookup (and Resolv would not resolve it).
      return [ host ] if literal_ip?(host)

      addresses = Resolv::DNS.open do |dns|
        dns.timeouts = 3
        (dns.getresources(host, Resolv::DNS::Resource::IN::A) +
         dns.getresources(host, Resolv::DNS::Resource::IN::AAAA)).map { |r| r.address.to_s }
      end

      raise UnsafeUrlError, "#{host} could not be resolved" if addresses.empty?

      addresses
    rescue Resolv::ResolvError, Resolv::ResolvTimeout
      raise UnsafeUrlError, "#{host} could not be resolved"
    end

    def literal_ip?(host)
      IPAddr.new(host)
      true
    rescue IPAddr::Error
      false
    end

    def blocked?(address)
      ip = IPAddr.new(address)
      BLOCKED_RANGES.any? { |range| range.include?(ip) }
    rescue IPAddr::Error
      true
    end
  end
end
