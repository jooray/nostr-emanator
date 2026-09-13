# frozen_string_literal: true

require "test_helper"

class NostrProfilePublisherServiceTest < ActiveSupport::TestCase
  def merge(existing, edits)
    service = Nostr::ProfilePublisherService.new(Account.new(pubkey_hex: "a" * 64))
    JSON.parse(service.send(:merge_content, existing, edits))
  end

  # The whole reason this merges instead of rebuilding: a kind 0 is REPLACEABLE,
  # so publishing a fresh object silently destroys every field the app does not
  # model. Losing somebody's nip05 or lightning address because they edited
  # their bio is data loss, not a missing feature.
  test "preserves fields the app does not model" do
    existing = JSON.generate({
      "name" => "juraj",
      "about" => "old bio",
      "nip05" => "juraj@example.com",
      "lud16" => "juraj@walletofsatoshi.com",
      "bot" => false,
      "some_client_extension" => { "nested" => true }
    })

    result = merge(existing, { "about" => "new bio" })

    assert_equal "new bio", result["about"]
    assert_equal "juraj@example.com", result["nip05"]
    assert_equal "juraj@walletofsatoshi.com", result["lud16"]
    assert_equal false, result["bot"]
    assert_equal({ "nested" => true }, result["some_client_extension"])
    assert_equal "juraj", result["name"]
  end

  test "nil means leave as is, empty string means clear" do
    existing = JSON.generate({ "name" => "juraj", "about" => "bio", "website" => "https://example.com" })

    result = merge(existing, { "name" => nil, "about" => "", "website" => "https://new.example" })

    assert_equal "juraj", result["name"], "nil must not touch the field"
    refute result.key?("about"), "empty string must remove the field"
    assert_equal "https://new.example", result["website"]
  end

  test "ignores keys outside the editable set" do
    result = merge(JSON.generate({ "name" => "juraj" }), { "pubkey" => "evil", "id" => "evil", "name" => "new" })

    assert_equal "new", result["name"]
    refute result.key?("pubkey")
    refute result.key?("id")
  end

  test "trims whitespace around values" do
    result = merge(nil, { "name" => "  juraj  ", "about" => "\tbio\n" })

    assert_equal "juraj", result["name"]
    assert_equal "bio", result["about"]
  end

  # A user whose profile is already broken must still be able to fix it.
  test "starts clean when the existing profile is not valid JSON" do
    result = merge("this is not json {{{", { "name" => "juraj" })

    assert_equal({ "name" => "juraj" }, result)
  end

  test "starts clean when the existing content is a JSON array rather than an object" do
    result = merge("[1,2,3]", { "name" => "juraj" })

    assert_equal({ "name" => "juraj" }, result)
  end

  test "handles no existing profile at all" do
    result = merge(nil, { "name" => "juraj", "display_name" => "Juraj" })

    assert_equal({ "name" => "juraj", "display_name" => "Juraj" }, result)
  end

  # --- created_at monotonicity ----------------------------------------------

  def created_at_for(existing)
    service = Nostr::ProfilePublisherService.new(Account.new(pubkey_hex: "a" * 64))
    service.send(:monotonic_created_at, existing)
  end

  test "uses now when the live profile is older" do
    now = Time.current.to_i

    assert_in_delta now, created_at_for(now - 500), 2
  end

  # Relays break a created_at tie by event id, which is effectively random, so
  # a same-second edit can lose to the copy it was meant to replace.
  test "lands strictly after a live profile stamped now or in the future" do
    now = Time.current.to_i

    assert_operator created_at_for(now), :>, now
    assert_operator created_at_for(now + 3600), :>, now + 3600
  end

  test "handles a missing created_at" do
    assert_in_delta Time.current.to_i, created_at_for(nil), 2
  end

  # --- capability gating -----------------------------------------------------

  test "refuses an account with no signer" do
    account = Account.new(pubkey_hex: "a" * 64)

    error = assert_raises(Nostr::ProfilePublisherService::PublishError) do
      Nostr::ProfilePublisherService.new(account).publish({ "name" => "x" })
    end
    assert_match(/no signer/i, error.message)
  end

  # Accounts paired before permission version 4 never requested sign_event:0.
  test "refuses an account paired before profile permission existed" do
    account = Account.new(
      pubkey_hex: "a" * 64, signer_pubkey: "b" * 64,
      app_pubkey: "c" * 64, app_privkey: "d" * 64,
      dm_perms_version: 3
    )

    error = assert_raises(Nostr::ProfilePublisherService::PublishError) do
      Nostr::ProfilePublisherService.new(account).publish({ "name" => "x" })
    end
    assert_match(/re-pair/i, error.message)
  end
end
