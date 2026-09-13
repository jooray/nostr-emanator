# frozen_string_literal: true

require_relative "../../test_helper"

class NostrContentTaggerTest < ActiveSupport::TestCase
  AUTHOR = "ef" * 32
  MENTION = "11" * 32
  QUOTED_ID = "ab" * 32
  QUOTED_AUTHOR = "cd" * 32

  def npub(hex = MENTION) = Nostr::KeyConverter.hex_to_npub(hex)

  def nevent(relays: [], author: QUOTED_AUTHOR, id: QUOTED_ID)
    Nostr::KeyConverter.hex_to_nevent(id, relays: relays, author_pubkey: author)
  end

  def tags_for(content, **kwargs)
    Nostr::ContentTagger.tags_for(content, author_pubkey: AUTHOR, **kwargs)
  end

  def test_mentions_become_p_tags
    assert_equal [["p", MENTION]], tags_for("ahoj nostr:#{npub}")
  end

  # The quote relationship lives in the tag, not in the text: without the `q`
  # no client draws the quoted note.
  def test_a_quoted_event_becomes_a_q_tag_and_notifies_its_author
    tags = tags_for("pozri nostr:#{nevent(relays: ['wss://nos.lol'])}")

    assert_equal ["q", QUOTED_ID, "wss://nos.lol", QUOTED_AUTHOR], tags.first
    assert_includes tags, ["p", QUOTED_AUTHOR, "wss://nos.lol"]
  end

  # The author slot is positional, so an unknown relay still needs its place.
  def test_quote_without_a_relay_hint_keeps_the_author_slot_reachable
    tags = tags_for("nostr:#{nevent}")

    assert_equal ["q", QUOTED_ID, "", QUOTED_AUTHOR], tags.first
  end

  def test_repeated_mentions_and_quotes_are_tagged_once
    text = "nostr:#{npub} ... nostr:#{npub} ... nostr:#{nevent} nostr:#{nevent}"
    tags = tags_for(text)

    assert_equal 1, tags.count { |t| t.first == "p" && t[1] == MENTION }
    assert_equal 1, tags.count { |t| t.first == "q" }
  end

  # A self-p would put every post the account writes into its own mentions feed.
  def test_the_authors_own_pubkey_is_not_tagged
    assert_empty tags_for("ja, nostr:#{npub(AUTHOR)}")
  end

  def test_callers_can_exclude_what_they_already_tagged
    tags = tags_for(
      "nostr:#{nevent} a nostr:#{npub}",
      exclude_event_ids: [QUOTED_ID],
      exclude_pubkeys: [MENTION]
    )

    assert_empty tags
  end

  def test_addressable_events_become_a_tags
    naddr = ::Bech32.encode(
      "naddr",
      Nostr::KeyConverter.send(:convert_bits, naddr_tlv, 8, 5),
      ::Bech32::Encoding::BECH32
    )
    tags = tags_for("nostr:#{naddr}")

    assert_equal ["a", "30023:#{QUOTED_AUTHOR}:my-article"], tags.first
    assert_includes tags, ["p", QUOTED_AUTHOR]
  end

  def test_hashtags_become_t_tags
    assert_equal [["t", "nostrautica"]], tags_for("vidíme sa #Nostrautica")
  end

  private

  def naddr_tlv
    identifier = "my-article".bytes
    tlv = [0, identifier.length] + identifier
    tlv += [2, 32] + [QUOTED_AUTHOR].pack("H*").bytes
    tlv += [3, 4] + [30_023].pack("N").bytes
    tlv
  end
end
