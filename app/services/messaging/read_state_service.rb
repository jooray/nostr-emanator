# frozen_string_literal: true

module Messaging
  # NIP-RS cross-device read state (kind 30078).
  #
  # No standard exists for syncing DM read state between Nostr clients — three
  # NIPs were proposed and two withdrawn by their own author. NIP-RS is the one
  # rigorous spec, and its value is the merge rule: a grow-only max register, so
  # two devices publishing concurrently can never fight.
  #
  #   effective[context] = max(timestamp) across every slot
  #
  # The local database stays the source of truth for the UI. This is best-effort
  # sync and must never block a render or a mark-read.
  #
  # https://github.com/block/buzz/blob/master/docs/nips/NIP-RS.md
  class ReadStateService
    CLIENT_ID = "emanator"

    def initialize(account)
      @account = account
    end

    # Record that everything up to `timestamp` in this conversation has been read.
    def mark_read(conversation, timestamp = Time.current)
      slot = own_slot
      return unless slot.merge_contexts!({ context_id(conversation) => timestamp.to_i })

      slot.mark_dirty!
    end

    # Our slot, created on first use. The slot id is random per installation so
    # two devices never contend for the same replaceable coordinate.
    def own_slot
      @account.read_state_slots.own_slot.first ||
        @account.read_state_slots.create!(
          slot_id: ReadStateSlot.generate_slot_id, client_id: CLIENT_ID, own: true, contexts: {}
        )
    end

    # Context ids. The spec declines to define a DM convention but names "pubkey
    # for DMs" as the natural identifier, so a 1:1 thread uses the bare peer
    # pubkey — the best chance of accidental interop. Groups and legacy threads
    # are namespaced so they cannot collide with it.
    def context_id(conversation)
      return "nip04:#{conversation.peer_pubkeys.first}" if conversation.legacy?
      return "nip17:#{conversation.participants_key}" if conversation.group?

      conversation.peer_pubkeys.first.to_s
    end

    # Fetch every slot for this account, import the peers, and apply the merged
    # result to local conversations.
    def sync!
      events = fetch_slots
      return if events.empty?

      events.each { |event| import(event) }
      apply_locally
    end

    # Read-before-write, then publish. Returns the signed event or nil.
    def publish!
      slot = own_slot
      sync!

      payload = { "v" => 1, "client_id" => slot.client_id || CLIENT_ID, "contexts" => slot.reload.context_map }
      return nil if payload["contexts"].empty?

      signed = sign(slot, payload)
      return nil unless signed

      # kind 30078 is app data rather than a DM, so the ordinary relay defaults
      # are correct here — unlike a gift wrap.
      results = Nostr::EventPublisherService.new.publish(signed, relays: @account.write_relays)
      slot.update!(dirty: false, last_published_at: Time.current, event_id: signed["id"]) if results.value?(:ok)
      signed
    end

    private

    def fetch_slots
      Nostr::EventFetcher.new(additional_relays: Array(@account.write_relays)).fetch_events(
        "kinds" => [ ReadStateSlot::KIND ],
        "authors" => [ @account.pubkey_hex ],
        "#t" => [ ReadStateSlot::TOPIC_TAG ],
        "since" => ReadStateSlot::HORIZON.ago.to_i
      )
    rescue StandardError => e
      Rails.logger.warn("Read-state fetch failed for account #{@account.id}: #{e.message}")
      []
    end

    def import(event)
      slot_id = d_tag(event)&.delete_prefix(ReadStateSlot::D_TAG_PREFIX)
      return if slot_id.blank?

      payload = decrypt(event)
      return unless payload.is_a?(Hash) && payload["contexts"].is_a?(Hash)

      slot = @account.read_state_slots.find_or_initialize_by(slot_id: slot_id)

      # Conflict: somebody else's installation is publishing at our coordinate.
      # Do not write there again — rotate to a fresh slot id instead.
      if slot.own? && payload["client_id"] != slot.client_id
        rotate_own_slot!
        return
      end

      slot.own = false if slot.new_record?
      slot.client_id ||= payload["client_id"]
      slot.last_seen_event_created_at = event["created_at"].to_i
      slot.save!
      slot.merge_contexts!(payload["contexts"])
    rescue StandardError => e
      Rails.logger.warn("Could not import a read-state slot: #{e.message}")
    end

    def rotate_own_slot!
      own_slot.update!(slot_id: ReadStateSlot.generate_slot_id, event_id: nil, last_published_at: nil)
      Rails.logger.warn("Read-state coordinate conflict for account #{@account.id}; rotated to a new slot")
    end

    # effective[context] = max across slots; never lower a local cursor.
    def apply_locally
      merged = @account.read_state_slots.reduce({}) do |acc, slot|
        slot.context_map.each { |context, ts| acc[context] = [ acc[context].to_i, ts.to_i ].max }
        acc
      end
      return if merged.empty?

      @account.conversations.find_each do |conversation|
        remote = merged[context_id(conversation)]
        next if remote.blank?

        remote_at = Time.at(remote.to_i).utc
        next if conversation.last_read_at.present? && conversation.last_read_at >= remote_at

        unread = conversation.messages.where(direction: "inbound").where("sort_at > ?", remote_at).count
        conversation.update!(last_read_at: remote_at, unread_count: unread)
      end

      Rails.cache.delete(MessagesHelper.unread_cache_key(@account.user))
    end

    def sign(slot, payload)
      Nostr::Nip46Rpc.open(@account) do |rpc|
        # Self-encryption: our own pubkey on both sides of the conversation key.
        content = rpc.call("nip44_encrypt", [ @account.pubkey_hex, JSON.generate(payload) ])

        unsigned = Nostr::EventSignerService.new.build_unsigned_event(
          content: content, kind: ReadStateSlot::KIND, pubkey: @account.pubkey_hex,
          created_at: created_at_for(slot),
          tags: [ [ "d", slot.d_tag ], [ "t", ReadStateSlot::TOPIC_TAG ] ]
        )

        JSON.parse(rpc.call("sign_event", [ JSON.generate(unsigned) ]))
      end
    rescue StandardError => e
      Rails.logger.warn("Read-state publish failed for account #{@account.id}: #{e.message}")
      nil
    end

    # Replaceable events are resolved by created_at, so a lagging local clock
    # would make our update lose to the copy already on the relay.
    def created_at_for(slot)
      [ Time.now.to_i, slot.last_seen_event_created_at.to_i + 1 ].max
    end

    def decrypt(event)
      Nostr::Nip46Rpc.open(@account) do |rpc|
        JSON.parse(rpc.call("nip44_decrypt", [ @account.pubkey_hex, event["content"] ]))
      end
    rescue StandardError
      nil
    end

    def d_tag(event)
      Array(event["tags"]).find { |tag| tag.is_a?(Array) && tag[0] == "d" }&.at(1)
    end
  end
end
