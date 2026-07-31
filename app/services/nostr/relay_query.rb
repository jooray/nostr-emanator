# frozen_string_literal: true

require "json"
require "securerandom"

module Nostr
  # One-shot REQ against a single relay: connect, subscribe, collect events until
  # EOSE (or the deadline), then CLOSE and disconnect.
  #
  # This is the single read path behind ProfileFetcher / EventFetcher /
  # RelayListFetcher, which each used to carry their own copy of the WebSocket
  # handshake and frame reader. Those copies built an SSLContext without
  # set_params (TLS verification disabled) and read relay-declared frame lengths
  # with unbounded, deadline-less blocking reads. Everything now goes through
  # WebsocketConnection (verified TLS, deadline-enforced handshake) and
  # WebsocketFrameReader (2 MB cap, deadline-enforced reads).
  class RelayQuery
    DEFAULT_TIMEOUT = 5

    # Returns an array of event hashes, or nil when the relay could not be
    # reached (callers distinguish "no events" from "no connection").
    # A block, if given, filters events; with stop_after_first: true the query
    # returns as soon as one event passes the filter.
    #
    # H3: every event handed back is cryptographically verified first — id,
    # Schnorr signature, and (unless `verify: false`) that its kind/author are
    # among the ones actually asked for. `kind:`/`author:` override what is
    # inferred from the filter. A relay that serves a forged or replayed event
    # for someone else's pubkey is therefore ignored, not trusted.
    # `auth:` opts in to NIP-42. It is a callable `->(relay_url, challenge) {
    # signed_22242_event | nil }`; passing nothing keeps the historical behaviour
    # exactly, which matters because this method backs profiles, contact lists,
    # mutes, mentions and relay lists. Only the DM read path needs authentication,
    # and only because two of the common inbox relays refuse to serve kind 1059
    # without it.
    def self.run(relay_url, filter, timeout: DEFAULT_TIMEOUT, stop_after_first: false,
                 kind: nil, author: nil, verify: true, auth: nil, &matcher)
      uri = URI.parse(relay_url)
      deadline = timeout.seconds.from_now
      socket = WebsocketConnection.open(uri, deadline: deadline)
      return nil unless socket

      sub_id = SecureRandom.hex(4)
      events = []
      challenge = nil
      authenticated = false
      # One re-subscription only: a relay that keeps demanding auth after a
      # successful one is refusing us, not negotiating.
      resubscribed = false

      begin
        WebsocketConnection.send_text(socket, ["REQ", sub_id, filter].to_json, deadline)

        while Time.current < deadline
          ready = WebsocketConnection.readable_now?(socket) ||
            IO.select([socket], nil, nil, WebsocketConnection.select_timeout(deadline, 0.5))
          next unless ready

          data = read_frame(socket, deadline)
          break unless data

          begin
            parsed = JSON.parse(data)
          rescue JSON::ParserError
            next
          end

          case parsed[0]
          when "EVENT"
            event = parsed[2]
            next unless event.is_a?(Hash)
            if verify && !authentic?(event, filter, kind, author)
              Rails.logger.warn("Dropping unverifiable event #{event["id"].to_s.first(16)} from #{relay_url}")
              next
            end
            next if matcher && !matcher.call(event)

            events << event
            break if stop_after_first
          when "AUTH"
            # May arrive on connect AND again with the rejection, carrying the
            # same value; last one wins.
            challenge = parsed[1]
          when "EOSE"
            break
          when "CLOSED"
            # A CLOSED destroys the subscription, so authenticating is not enough
            # on its own — the REQ has to be sent again.
            break unless auth && !resubscribed && RelayAuth.classify(parsed[2]) == :auth_required

            RelayAuth.remember_requires_auth!(relay_url)
            break unless challenge && !authenticated

            authenticated = authenticate(socket, relay_url, challenge, auth, deadline)
            break unless authenticated

            resubscribed = true
            sub_id = SecureRandom.hex(4)
            WebsocketConnection.send_text(socket, ["REQ", sub_id, filter].to_json, deadline)
          end
        end

        events
      ensure
        # Fresh short deadline: the query deadline is usually already spent.
        close(socket, sub_id, 1.second.from_now)
      end
    end

    # Sign a kind-22242 for this challenge and wait for the relay's OK.
    def self.authenticate(socket, relay_url, challenge, auth, deadline)
      signed = auth.call(relay_url, challenge)
      return false unless signed

      WebsocketConnection.send_text(socket, ["AUTH", signed].to_json, deadline)

      while Time.current < deadline
        ready = WebsocketConnection.readable_now?(socket) ||
          IO.select([socket], nil, nil, WebsocketConnection.select_timeout(deadline, 0.5))
        next unless ready

        data = read_frame(socket, deadline)
        return false unless data

        begin
          parsed = JSON.parse(data)
        rescue JSON::ParserError
          next
        end

        next unless parsed[0] == "OK" && parsed[1] == signed["id"]

        Rails.logger.warn("NIP-42 rejected by #{relay_url}: #{parsed[3].inspect}") unless parsed[2]
        return parsed[2] == true
      end

      false
    rescue StandardError => e
      Rails.logger.warn("NIP-42 authentication failed on #{relay_url}: #{e.message}")
      false
    end

    # Signature/id check plus "is this actually what we subscribed to": a relay
    # may only answer with events of the kinds and (when the filter named them)
    # the authors of the REQ it was given.
    def self.authentic?(event, filter, kind, author)
      return false unless EventValidator.valid?(event)

      kinds = kind ? [ kind ] : Array(filter_value(filter, "kinds"))
      return false if kinds.present? && !kinds.map(&:to_i).include?(event["kind"])

      authors = author ? [ author ] : Array(filter_value(filter, "authors"))
      if authors.present?
        return false unless authors.map { |a| a.to_s.downcase }.include?(event["pubkey"].to_s.downcase)
      end

      ids = Array(filter_value(filter, "ids"))
      if ids.present?
        return false unless ids.map { |i| i.to_s.downcase }.include?(event["id"].to_s.downcase)
      end

      true
    end

    def self.filter_value(filter, key)
      return nil unless filter.respond_to?(:[])
      filter[key] || filter[key.to_sym]
    end

    def self.read_frame(socket, deadline)
      WebsocketFrameReader.read(socket, deadline: deadline)
    rescue WebsocketFrameReader::FrameError
      nil
    end

    def self.close(socket, sub_id, deadline)
      WebsocketConnection.send_text(socket, ["CLOSE", sub_id].to_json, deadline) rescue nil
      socket.close rescue nil
    end

    private_class_method :read_frame, :close, :authentic?, :filter_value
  end
end
