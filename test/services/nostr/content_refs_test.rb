# frozen_string_literal: true

require_relative "../../test_helper"

class NostrContentRefsTest < ActiveSupport::TestCase
  NPUB = Nostr::KeyConverter.hex_to_npub("11" * 32)

  def nevent(relays: [], author: nil)
    Nostr::KeyConverter.hex_to_nevent("ab" * 32, relays: relays, author_pubkey: author)
  end

  def test_bare_identifiers_are_rewritten_to_nostr_uris
    normalized = Nostr::ContentRefs.normalize("ahoj #{NPUB} tak")

    assert_equal "ahoj nostr:#{NPUB} tak", normalized
  end

  def test_normalize_is_idempotent
    once = Nostr::ContentRefs.normalize("hi #{NPUB}")

    assert_equal once, Nostr::ContentRefs.normalize(once)
  end

  # A bech32 identifier is only rewritten when it decodes, so prose is never
  # mangled into a fake mention.
  def test_undecodable_identifiers_are_left_alone
    broken = "#{NPUB.chop}q"
    text = "note1thisisnotrealatall and #{broken}"

    assert_equal text, Nostr::ContentRefs.normalize(text)
    assert_empty Nostr::ContentRefs.scan(text)
  end

  def test_identifiers_inside_urls_are_not_rewritten
    url = "https://njump.me/#{NPUB}"

    assert_equal url, Nostr::ContentRefs.normalize(url)
  end

  def test_scan_decodes_every_entity_type_in_order
    text = "#{NPUB} then #{nevent(author: 'cd' * 32)}"
    refs = Nostr::ContentRefs.scan(text)

    assert_equal [:npub, :nevent], refs.map(&:type)
    assert_equal "11" * 32, refs.first.pubkey
    assert_equal "ab" * 32, refs.last.event_id
    assert_equal "cd" * 32, refs.last.author
  end

  def test_scan_keeps_only_websocket_relay_hints
    ref = Nostr::ContentRefs.scan(nevent(relays: ["wss://relay.damus.io", "http://evil.example"])).first

    assert_equal ["wss://relay.damus.io"], ref.relays
  end

  def test_hashtags_need_a_letter_and_are_downcased
    assert_equal ["nostrautica", "ekonómia"],
                 Nostr::ContentRefs.hashtags("#Nostrautica a #ekonómia, ale nie #2026")
  end

  def test_hashtags_ignore_url_fragments
    assert_empty Nostr::ContentRefs.hashtags("https://example.com/page#section")
  end
end
