# frozen_string_literal: true

require "digest"
require "json"
require "schnorr"
require "securerandom"

module Nostr
  # NIP-17 private direct messages, layered over NIP-59 gift wrap.
  #
  #   rumor (kind 14/15, UNSIGNED)
  #     └─ nip44(sender_priv, receiver_pub)  -> seal (kind 13, signed by SENDER)
  #          └─ nip44(ephemeral_priv, receiver_pub) -> gift wrap (kind 1059,
  #                                                    signed by a THROWAWAY key)
  #
  # Everything here is a pure function: no relay I/O, no signer round-trips, no
  # database. That is deliberate — the security-critical logic is in `parse_seal`
  # / `parse_rumor`, and keeping it side-effect free means it can be tested
  # against real crypto with zero stubs.
  #
  # Note which layers we can do ourselves. The app holds an account's NIP-46
  # delegation key, never its identity key, so sealing and unsealing must go
  # through the remote signer (Nip46Rpc). The gift wrap is the exception: it uses
  # a keypair we generate and discard, so `build_wrap` is fully local.
  #
  # Specs: https://github.com/nostr-protocol/nips/blob/master/17.md
  #        https://github.com/nostr-protocol/nips/blob/master/59.md
  module Nip17
    CHAT_KIND       = 14
    FILE_KIND       = 15
    SEAL_KIND       = 13
    WRAP_KIND       = 1059
    RELAY_LIST_KIND = 10_050

    RUMOR_KINDS = [ CHAT_KIND, FILE_KIND ].freeze

    # "Clients SHOULD randomize created_at in up to two days in the past in both
    # the seal and the gift wrap" (NIP-17). Backdating only: some relays reject
    # future-dated events outright — inbox.nostr.wine caps skew at 300 s.
    MAX_BACKDATE = 2 * 24 * 60 * 60

    # Tags carrying the AES parameters of a kind-15 encrypted file. These are
    # secrets: whoever has them can decrypt the blob off the media server.
    FILE_TAGS = %w[
      file-type encryption-algorithm decryption-key decryption-nonce
      x ox size dim thumbhash blurhash thumb fallback
    ].freeze

    HEX_32 = /\A[0-9a-f]{64}\z/

    # A rumor we refused to accept. Always permanent — malformed or hostile input
    # will not become valid on retry, so callers should record the reason and
    # stop rather than spending another signer round-trip.
    class RejectedError < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason.to_s.tr("_", " "))
      end
    end

    Message = Data.define(
      :kind, :sender_pubkey, :content, :participants, :participants_key,
      :subject, :reply_to_rumor_id, :quoted_rumor_id, :rumor_id,
      :rumor_created_at, :seal_created_at, :tags, :file_metadata,
      :pubkey_recovered, :rumor_id_recomputed
    ) do
      def chat? = kind == CHAT_KIND
      def file? = kind == FILE_KIND
      def group? = participants.size > 2
    end

    class << self
      # ---------------------------------------------------------------- outbound

      # An unsigned kind-14/15 rumor. `id` and `created_at` are required by the
      # spec, and `created_at` is the *real* time — only the seal and wrap get
      # randomised, so this is the only honest timestamp in the stack.
      #
      # `recipients` are the other participants; the room is this set plus the
      # sender. Adding or removing one produces a different room, not an edit.
      def build_rumor(kind:, content:, sender_pubkey:, recipients:,
                      reply_to: nil, subject: nil, quote: nil,
                      relay_hints: {}, extra_tags: [], created_at: Time.now.to_i)
        raise ArgumentError, "unsupported rumor kind #{kind}" unless RUMOR_KINDS.include?(kind)

        tags = recipients.map { |pubkey| [ "p", pubkey, relay_hints[pubkey].to_s ].compact_blank }
        tags << [ "e", reply_to[:id], reply_to[:relay].to_s ].compact_blank if reply_to
        tags << [ "subject", subject ] if subject.present?
        tags << [ "q", quote[:id], quote[:relay].to_s, quote[:pubkey].to_s ].compact_blank if quote
        tags.concat(extra_tags)

        rumor = {
          "pubkey" => sender_pubkey,
          "created_at" => created_at,
          "kind" => kind,
          "tags" => tags,
          "content" => content
        }
        rumor["id"] = EventValidator.event_id(rumor)
        rumor
      end

      # An unsigned kind-13 seal, for the remote signer to sign. `tags` MUST stay
      # empty — the seal reveals the author and nothing else.
      def build_seal(sealed_content:, sender_pubkey:, created_at: randomized_past)
        seal = {
          "pubkey" => sender_pubkey,
          "created_at" => created_at,
          "kind" => SEAL_KIND,
          "tags" => [],
          "content" => sealed_content
        }
        seal["id"] = EventValidator.event_id(seal)
        seal
      end

      # A complete, signed kind-1059 gift wrap. Local: the wrapper keypair is
      # generated here and thrown away, which is what hides the sender from the
      # relay. A fresh key per wrap is required — reusing one links messages.
      def build_wrap(seal:, recipient_pubkey:, relay_hint: nil, created_at: nil)
        keypair = ::Nostr::Keygen.new.generate_key_pair
        ephemeral_pubkey = keypair.public_key.to_s
        ephemeral_privkey = keypair.private_key.to_s

        content = Nip44.encrypt(
          Nip44.conversation_key(ephemeral_privkey, recipient_pubkey),
          JSON.generate(seal)
        )

        wrap = {
          "pubkey" => ephemeral_pubkey,
          # Randomised independently of the seal: correlated timestamps across
          # layers would undo the point of randomising either.
          "created_at" => created_at || randomized_past,
          "kind" => WRAP_KIND,
          "tags" => [ [ "p", recipient_pubkey, relay_hint.to_s ].compact_blank ],
          "content" => content
        }
        wrap["id"] = EventValidator.event_id(wrap)
        wrap["sig"] = sign(wrap["id"], ephemeral_privkey)
        wrap
      end

      # Uniformly distributed over [now - max, now]. SecureRandom rather than
      # rand: this is a timing-correlation defence, so it must not be predictable.
      def randomized_past(max: MAX_BACKDATE, now: Time.now.to_i)
        now - SecureRandom.random_number(max + 1)
      end

      # A room's identity is its participant set (NIP-17 has no room id), so this
      # is order-independent and includes every participant, sender included.
      def participants_key(pubkeys)
        Digest::SHA256.hexdigest(normalize_participants(pubkeys).join(","))
      end

      # ----------------------------------------------------------------- inbound

      def valid_wrap?(event, recipient_pubkey:)
        EventValidator.valid?(event, kind: WRAP_KIND, recipient: recipient_pubkey)
      end

      # Parse the plaintext recovered from a gift wrap's content. Returns the
      # seal hash; raises RejectedError otherwise.
      def parse_seal(json)
        seal = parse_json(json, :seal_not_json)
        raise RejectedError, :seal_not_an_object unless seal.is_a?(Hash)
        raise RejectedError, :seal_wrong_kind unless seal["kind"] == SEAL_KIND
        # Full signature check: this is the only thing binding the message to its
        # author, since the wrap is signed by a throwaway key.
        raise RejectedError, :seal_invalid_signature unless EventValidator.valid?(seal, kind: SEAL_KIND)

        seal
      end

      # Parse the plaintext recovered from a seal's content into a Message.
      # Raises RejectedError on anything malformed or hostile.
      def parse_rumor(json, seal:, recipient_pubkey:, wrap_event: nil)
        rumor = parse_json(json, :rumor_not_json)
        raise RejectedError, :rumor_not_an_object unless rumor.is_a?(Hash)
        # Gift wrap is a general-purpose envelope (NIP-59), so plenty of traffic
        # addressed to us is legitimately not a chat message: NIP-17 itself allows
        # kind-7 reactions in a room, and other NIPs wrap wallet and calendar
        # events the same way. Naming the kind makes those distinguishable from
        # actually-malformed input instead of one opaque bucket.
        unless RUMOR_KINDS.include?(rumor["kind"])
          raise RejectedError, :"unsupported_rumor_kind_#{rumor["kind"]}"
        end
        raise RejectedError, :rumor_content_not_a_string unless rumor["content"].is_a?(String)

        sender_pubkey, pubkey_recovered = resolve_sender(rumor, seal)

        # A rumor is unsigned, so nothing stops a sender from writing someone
        # else's pubkey into it. The seal IS signed, so the seal's author is the
        # only trustworthy identity — a mismatch is an impersonation attempt.
        # 0xchat and welshman reject here too; Amethyst instead overwrites the
        # rumor's pubkey, which is equally safe but shows the message rather than
        # dropping it, so don't expect identical behaviour cross-client.
        if sender_pubkey.downcase != seal["pubkey"].downcase
          raise RejectedError, :seal_pubkey_mismatch
        end

        # Fall back to the seal when the rumor omits created_at (Amethyst does).
        # The seal's value is randomised into the past, so it is a poor
        # timestamp — but it beats nil, and `sort_at` clamps it anyway.
        created_at = integer_or_nil(rumor["created_at"]) || seal["created_at"]

        # Computed over the rumor's OWN tags with pubkey/created_at filled in, so
        # a rumor that merely omitted them still hashes to the id its sender
        # computed. Merged seal tags are deliberately excluded — including them
        # would change the id of a message we can otherwise read verbatim.
        rumor_id, rumor_id_recomputed = resolve_rumor_id(rumor, sender_pubkey, created_at)

        # Amethyst merges the seal's tags into the rumor's, so tolerate a
        # non-empty seal rather than rejecting a message we can read.
        tags = normalized_tags(rumor["tags"]) + normalized_tags(seal["tags"])

        participants = normalize_participants([ sender_pubkey ] + p_tag_pubkeys(tags))
        unless participants.include?(recipient_pubkey.downcase)
          raise RejectedError, :not_addressed_to_us
        end

        Message.new(
          kind: rumor["kind"],
          sender_pubkey: sender_pubkey.downcase,
          content: rumor["content"],
          participants: participants,
          participants_key: participants_key(participants),
          subject: tag_value(tags, "subject"),
          reply_to_rumor_id: hex_tag_value(tags, "e"),
          quoted_rumor_id: hex_tag_value(tags, "q"),
          rumor_id: rumor_id,
          rumor_created_at: created_at,
          seal_created_at: seal["created_at"],
          tags: tags,
          file_metadata: rumor["kind"] == FILE_KIND ? file_metadata(tags) : nil,
          pubkey_recovered: pubkey_recovered,
          rumor_id_recomputed: rumor_id_recomputed
        )
      end

      # Unwrap end to end with a locally held private key.
      #
      # Production does NOT use this: the two decryptions need the account's
      # identity key, which lives in the user's signer, so DecryptGiftWrapsJob
      # drives them through Nip46Rpc. This exists because it is the exact inverse
      # of build_wrap, which makes the round-trip testable without stubs.
      def open_wrap(wrap_event:, recipient_privkey:, recipient_pubkey:)
        seal_json = Nip44.decrypt(
          Nip44.conversation_key(recipient_privkey, wrap_event["pubkey"]),
          wrap_event["content"]
        )
        seal = parse_seal(seal_json)

        rumor_json = Nip44.decrypt(
          Nip44.conversation_key(recipient_privkey, seal["pubkey"]),
          seal["content"]
        )
        parse_rumor(rumor_json, seal: seal, recipient_pubkey: recipient_pubkey, wrap_event: wrap_event)
      end

      private

      def parse_json(json, reason)
        JSON.parse(json.to_s)
      rescue JSON::ParserError
        raise RejectedError, reason
      end

      # A missing rumor pubkey is recoverable from the signed seal — there is no
      # contradicting claim, so this is leniency rather than a security hole.
      def resolve_sender(rumor, seal)
        claimed = rumor["pubkey"]
        return [ claimed, false ] if claimed.is_a?(String) && claimed.match?(HEX_32)
        return [ seal["pubkey"], true ] if claimed.nil?

        raise RejectedError, :rumor_pubkey_malformed
      end

      def resolve_rumor_id(rumor, sender_pubkey, created_at)
        computed = EventValidator.event_id(
          rumor.merge("pubkey" => sender_pubkey, "created_at" => created_at)
        )
        claimed = rumor["id"]
        return [ claimed.downcase, false ] if claimed.is_a?(String) && claimed.downcase == computed

        [ computed, true ]
      end

      def normalized_tags(tags)
        return [] unless tags.is_a?(Array)

        tags.select { |tag| tag.is_a?(Array) && tag[0].is_a?(String) }
      end

      def p_tag_pubkeys(tags)
        tags.filter_map { |tag| tag[1] if tag[0] == "p" && tag[1].is_a?(String) && tag[1].match?(HEX_32) }
      end

      def normalize_participants(pubkeys)
        pubkeys.filter_map { |pk| pk.to_s.downcase.presence }.uniq.sort
      end

      def tag_value(tags, name)
        tags.find { |tag| tag[0] == name && tag[1].is_a?(String) }&.at(1).presence
      end

      def hex_tag_value(tags, name)
        value = tag_value(tags, name)&.downcase
        value if value&.match?(HEX_32)
      end

      def file_metadata(tags)
        FILE_TAGS.index_with { |name| tag_value(tags, name) }.compact.presence
      end

      def integer_or_nil(value)
        value if value.is_a?(Integer)
      end

      def sign(event_id, privkey_hex)
        Schnorr.sign([ event_id ].pack("H*"), [ privkey_hex ].pack("H*")).encode.unpack1("H*")
      end
    end
  end
end
