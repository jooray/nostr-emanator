# frozen_string_literal: true

require "test_helper"

class NostrContentHelperTest < ActionView::TestCase
  tests NostrContentHelper
  include ActiveJob::TestHelper

  # 32 zero bytes -> a valid npub, so the helper takes the profile-reference path.
  PUBKEY = "00" * 32
  NPUB = Nostr::KeyConverter.hex_to_npub(PUBKEY)

  setup do
    # nprofile_url consults the viewer's preferred event viewer.
    def view.current_user = nil

    # The test env uses the null store; these tests are about cache behaviour.
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
    Rails.cache = @previous_cache
  end

  test "escapes plain content" do
    assert_equal "&lt;script&gt;", view.render_nostr_content("<script>")
  end

  test "a cold mention renders the fallback without touching a relay" do
    Nostr::ProfileFetcher.stub_any_instance_fetch = ->(_) { flunk("relay fetch during render") }

    html = view.render_nostr_content("hello nostr:#{NPUB}")

    assert_includes html, NPUB.truncate(20)
    assert_enqueued_with(job: WarmNostrReferenceJob, args: [ "profile", PUBKEY ])
  ensure
    Nostr::ProfileFetcher.stub_any_instance_fetch = nil
  end

  test "repeated cold mentions enqueue the warm-up only once" do
    view.render_nostr_content("nostr:#{NPUB} and again nostr:#{NPUB}")

    assert_equal 1, enqueued_jobs.count { |j| j[:job] == WarmNostrReferenceJob }
  end

  test "a warmed profile renders the display name" do
    Rails.cache.write(WarmNostrReferenceJob.profile_cache_key(PUBKEY), { display_name: "Alice" })

    assert_includes view.render_nostr_content("nostr:#{NPUB}"), "@Alice"
    assert_no_enqueued_jobs only: WarmNostrReferenceJob
  end
end

# Minimal seam so the test above can assert rendering never calls the fetcher
# (Minitest 6 dropped minitest/mock, and the app has no mocking gem).
module Nostr
  class ProfileFetcher
    class << self
      attr_accessor :stub_any_instance_fetch
    end

    alias_method :fetch_without_test_stub, :fetch

    def fetch(pubkey_hex, *args, **kwargs)
      stub = self.class.stub_any_instance_fetch
      return stub.call(pubkey_hex) if stub

      fetch_without_test_stub(pubkey_hex, *args, **kwargs)
    end
  end
end
