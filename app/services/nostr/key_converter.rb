# frozen_string_literal: true

require "bech32"

module Nostr
  class KeyConverter
    # TLV type constants for NIP-19 shareable identifiers
    TLV_SPECIAL = 0   # event id or pubkey
    TLV_RELAY = 1     # relay URL
    TLV_AUTHOR = 2    # author pubkey
    TLV_KIND = 3      # event kind

    class << self
      def hex_to_npub(hex_pubkey)
        return nil if hex_pubkey.blank?

        bytes = [hex_pubkey].pack("H*").bytes
        ::Bech32.encode("npub", convert_bits(bytes, 8, 5), ::Bech32::Encoding::BECH32)
      end

      def hex_to_note(hex_event_id)
        return nil if hex_event_id.blank?

        bytes = [hex_event_id].pack("H*").bytes
        ::Bech32.encode("note", convert_bits(bytes, 8, 5), ::Bech32::Encoding::BECH32)
      end

      def npub_to_hex(npub)
        return nil if npub.blank?
        return npub if npub.match?(/\A[0-9a-f]{64}\z/i)

        hrp, data, _spec = ::Bech32.decode(npub)
        return nil unless hrp == "npub"

        bytes = convert_bits(data, 5, 8, false)
        bytes.pack("C*").unpack1("H*")
      end

      def note_to_hex(note)
        return nil if note.blank?
        return note if note.match?(/\A[0-9a-f]{64}\z/i)

        hrp, data, _spec = ::Bech32.decode(note)
        return nil unless hrp == "note"

        bytes = convert_bits(data, 5, 8, false)
        bytes.pack("C*").unpack1("H*")
      rescue StandardError
        nil
      end

      def valid_npub?(npub)
        return false if npub.blank?

        hrp, data, _spec = ::Bech32.decode(npub)
        hrp == "npub" && data.length == 52
      rescue StandardError
        false
      end

      def hex_to_nevent(hex_event_id, relays: [], author_pubkey: nil)
        return nil if hex_event_id.blank?

        tlv = []
        # Type 0: event id (32 bytes)
        event_bytes = [hex_event_id].pack("H*").bytes
        tlv << 0 << 32
        tlv.concat(event_bytes)

        # Type 1: relay hints
        relays.each do |relay|
          relay_bytes = relay.encode("UTF-8").bytes
          tlv << 1 << relay_bytes.length
          tlv.concat(relay_bytes)
        end

        # Type 2: author pubkey (32 bytes)
        if author_pubkey.present?
          author_bytes = [author_pubkey].pack("H*").bytes
          tlv << 2 << 32
          tlv.concat(author_bytes)
        end

        ::Bech32.encode("nevent", convert_bits(tlv, 8, 5), ::Bech32::Encoding::BECH32)
      end

      # Decode nevent back to components
      def nevent_to_hex(nevent)
        return nil if nevent.blank?

        hrp, data, _spec = ::Bech32.decode(nevent, nevent.length + 10)
        return nil unless hrp == "nevent"

        bytes = convert_bits(data, 5, 8, false)
        return nil if bytes.nil?

        result = { event_id: nil, relays: [], author: nil, kind: nil }
        i = 0

        while i < bytes.length
          type = bytes[i]
          length = bytes[i + 1]
          break if length.nil? || i + 2 + length > bytes.length

          value = bytes[i + 2, length]

          case type
          when TLV_SPECIAL
            result[:event_id] = value.pack("C*").unpack1("H*")
          when TLV_RELAY
            result[:relays] << value.pack("C*")
          when TLV_AUTHOR
            result[:author] = value.pack("C*").unpack1("H*")
          when TLV_KIND
            result[:kind] = value.pack("C*").unpack1("N")
          end

          i += 2 + length
        end

        result
      end

      # Decode naddr1 to components (kind, pubkey, d-tag, relays)
      def naddr_to_components(naddr)
        return nil if naddr.blank?

        hrp, data, _spec = ::Bech32.decode(naddr, naddr.length + 10)
        return nil unless hrp == "naddr"

        bytes = convert_bits(data, 5, 8, false)
        return nil if bytes.nil?

        result = { identifier: nil, relays: [], pubkey: nil, kind: nil }
        i = 0

        while i < bytes.length
          type = bytes[i]
          length = bytes[i + 1]
          break if length.nil? || i + 2 + length > bytes.length

          value = bytes[i + 2, length]

          case type
          when TLV_SPECIAL # d-tag identifier
            result[:identifier] = value.pack("C*")
          when TLV_RELAY
            result[:relays] << value.pack("C*")
          when TLV_AUTHOR
            result[:pubkey] = value.pack("C*").unpack1("H*")
          when TLV_KIND
            result[:kind] = value.pack("C*").unpack1("N")
          end

          i += 2 + length
        end

        result
      rescue StandardError
        nil
      end

      # Decode nprofile back to components (pubkey + relay hints)
      def nprofile_to_components(nprofile)
        return nil if nprofile.blank?

        hrp, data, _spec = ::Bech32.decode(nprofile, nprofile.length + 10)
        return nil unless hrp == "nprofile"

        bytes = convert_bits(data, 5, 8, false)
        return nil if bytes.nil?

        result = { pubkey: nil, relays: [] }
        i = 0

        while i < bytes.length
          type = bytes[i]
          length = bytes[i + 1]
          break if length.nil? || i + 2 + length > bytes.length

          value = bytes[i + 2, length]

          case type
          when TLV_SPECIAL
            result[:pubkey] = value.pack("C*").unpack1("H*")
          when TLV_RELAY
            result[:relays] << value.pack("C*")
          end

          i += 2 + length
        end

        result
      rescue StandardError
        nil
      end

      # Parse any nostr identifier and return structured data
      def parse_nostr_identifier(identifier)
        return nil if identifier.blank?

        id = identifier.sub(/\Anostr:/i, "")

        if id.start_with?("note1")
          { type: :note, event_id: note_to_hex(id) }
        elsif id.start_with?("nevent1")
          data = nevent_to_hex(id)
          { type: :nevent, event_id: data&.dig(:event_id), relays: data&.dig(:relays), author: data&.dig(:author) }
        elsif id.start_with?("naddr1")
          data = naddr_to_components(id)
          { type: :naddr, identifier: data&.dig(:identifier), kind: data&.dig(:kind), pubkey: data&.dig(:pubkey) }
        elsif id.start_with?("nprofile1")
          data = nprofile_to_components(id)
          { type: :nprofile, pubkey: data&.dig(:pubkey), relays: data&.dig(:relays) }
        elsif id.start_with?("npub1")
          { type: :npub, pubkey: npub_to_hex(id) }
        elsif id.match?(/\A[0-9a-f]{64}\z/i)
          { type: :hex, event_id: id }
        end
      rescue StandardError
        nil
      end

      def valid_hex_pubkey?(hex)
        return false if hex.blank?

        hex.match?(/\A[0-9a-f]{64}\z/i)
      end

      private

      def convert_bits(data, from_bits, to_bits, pad = true)
        acc = 0
        bits = 0
        ret = []
        maxv = (1 << to_bits) - 1
        max_acc = (1 << (from_bits + to_bits - 1)) - 1

        data.each do |value|
          acc = ((acc << from_bits) | value) & max_acc
          bits += from_bits
          while bits >= to_bits
            bits -= to_bits
            ret << ((acc >> bits) & maxv)
          end
        end

        if pad && bits > 0
          ret << ((acc << (to_bits - bits)) & maxv)
        elsif bits >= from_bits || ((acc << (to_bits - bits)) & maxv) != 0
          return nil
        end

        ret
      end
    end
  end
end
