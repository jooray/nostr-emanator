# frozen_string_literal: true

require_relative "../test_helper"

# A reply whose signature never came back (a phone on a bad connection) sat on
# the dashboard with a Retry that answered "Cannot retry publishing.": the row
# always asked to publish, and there was nothing signed to publish. Reschedule,
# the other way out, went through the scheduler, which builds a plain note and
# would have sent the reply as a standalone post.
class FailedNoteRetryTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper
  include ApiTestHelper
  include ActiveJob::TestHelper

  def setup
    @user = create_signed_in_user
    @account = create_signed_account(@user)
    @parent_id = SecureRandom.hex(32)
    @reply = @account.posts.create!(
      content: "it's pretty new", status: :failed, is_reply: true,
      reply_to_event_id: @parent_id, reply_to_pubkey: SecureRandom.hex(32),
      scheduled_at: 2.days.ago,
      unsigned_event: { "kind" => 1, "created_at" => 2.days.ago.to_i, "content" => "it's pretty new", "tags" => [] },
      publish_results: { "error" => "Signing timed out" }
    )
  end

  def test_the_dashboard_retry_asks_the_signer_for_an_unsigned_note
    get dashboard_path

    assert_response :success
    assert_match(%r{/posts/#{@reply.id}/retry_sign}, response.body)
    assert_no_match(%r{/posts/#{@reply.id}/retry_publish}, response.body)
  end

  def test_retry_publish_of_an_unsigned_note_signs_it_instead
    assert_enqueued_with(job: SignPostJob, args: [ @reply.id ]) do
      post retry_publish_post_path(@reply)
    end

    assert_redirected_to post_path(@reply)
    assert_equal "awaiting_signature", @reply.reload.status
  end

  def test_a_retried_reply_is_rebuilt_as_a_reply_dated_now
    post retry_sign_post_path(@reply)

    @reply.reload
    assert_equal "awaiting_signature", @reply.status
    assert_nil @reply.publish_results
    assert_in_delta Time.current.to_i, @reply.unsigned_event["created_at"], 5
    assert_in_delta Time.current.to_i, @reply.scheduled_at.to_i, 5
    assert_includes @reply.unsigned_event["tags"].map { |t| t.first(2) }, [ "e", @parent_id ]
  end

  def test_a_reply_cannot_be_rescheduled_and_shows_what_it_answers
    refute @reply.can_reschedule?

    get post_path(@reply)

    assert_response :success
    assert_no_match(%r{/posts/#{@reply.id}/reschedule}, response.body)
    assert_includes response.body, I18n.t("posts.show.in_reply_to")
  end

  def test_the_api_retry_publish_signs_an_unsigned_reply
    @device_token = ApiToken.issue_device!(@user, name: "Test phone", client_version: "1")
    api_post "/api/v1/posts/#{@reply.id}/retry_publish"

    assert_response :success
    assert_equal "awaiting_signature", json.dig("post", "status")
    refute json.dig("post", "can", "reschedule")
    assert json.dig("post", "reply_to_nevent").start_with?("nevent1")
  end

  # The same holds for an ordinary note: signed with the hour it missed, it
  # would go out below everything posted since and nobody would see it.
  def test_a_retried_note_that_missed_its_hour_is_dated_now_with_its_reposts
    other = create_signed_account(@user, display_name: "Resharer")
    note = failed_note(at: 2.days.ago)
    repost = note.reposts.create!(account: other, status: :failed, delay_minutes: 30, scheduled_at: 2.days.ago + 30.minutes,
                                  unsigned_event: { "kind" => 6, "content" => "{}", "tags" => [] })

    assert_enqueued_with(job: SignPostJob, args: [ note.id ]) do
      post retry_sign_post_path(note)
    end

    note.reload
    repost.reload
    assert_equal "awaiting_signature", note.status
    assert_in_delta Time.current.to_i, note.unsigned_event["created_at"], 5
    assert_in_delta Time.current.to_i, note.scheduled_at.to_i, 5

    assert_equal "awaiting_signature", repost.status, "a repost failed while the note waited comes back with it"
    assert_in_delta (Time.current + 30.minutes).to_i, repost.unsigned_event["created_at"], 5
    assert_in_delta (Time.current + 30.minutes).to_i, repost.scheduled_at.to_i, 5
    assert_equal note.unsigned_event["id"], JSON.parse(repost.unsigned_event["content"])["id"],
                 "the repost must embed the re-dated note, not the one that was never signed"
  end

  def test_a_retried_note_still_ahead_of_its_hour_keeps_it
    at = 3.hours.from_now.change(usec: 0)
    note = failed_note(at: at)

    post retry_sign_post_path(note)

    note.reload
    assert_equal at, note.scheduled_at
    assert_equal at.to_i, note.unsigned_event["created_at"]
  end

  # Signed, but no relay ever took it: sending that event a day later buries it
  # just the same, so Retry publishing asks for a new signature instead.
  def test_retry_publishing_a_stale_unsent_note_signs_it_again_dated_now
    note = signed_failed_note(signed_at: 1.day.ago)

    assert_enqueued_with(job: SignPostJob, args: [ note.id ]) do
      post retry_publish_post_path(note)
    end

    note.reload
    assert_equal "awaiting_signature", note.status
    assert_nil note.signed_event
    assert_nil note.event_id
    assert_in_delta Time.current.to_i, note.unsigned_event["created_at"], 5
    assert_equal I18n.t("posts.flash.resigning_stale"), flash[:notice]
  end

  def test_retry_publishing_a_stale_unsent_reply_keeps_it_a_reply
    @reply.update!(signed_event: { "id" => "ab" * 32, "created_at" => 1.day.ago.to_i, "sig" => "x" }, event_id: "ab" * 32)

    post retry_publish_post_path(@reply)

    @reply.reload
    assert_equal "awaiting_signature", @reply.status
    assert_includes @reply.unsigned_event["tags"].map { |t| t.first(2) }, [ "e", @parent_id ]
  end

  def test_retry_publishing_a_recently_signed_note_sends_it_as_it_is
    note = signed_failed_note(signed_at: 5.minutes.ago)

    assert_enqueued_with(job: PublishPostJob, args: [ note.id ]) do
      post retry_publish_post_path(note)
    end
    assert_equal "scheduled", note.reload.status
    assert note.signed_event.present?
  end

  def test_retry_publishing_a_note_a_relay_accepted_does_not_re_date_it
    note = signed_failed_note(signed_at: 1.day.ago, results: { "wss://a.example" => "ok", "wss://b.example" => "timeout" })

    assert_enqueued_with(job: PublishPostJob, args: [ note.id ]) do
      post retry_publish_post_path(note)
    end
    assert note.reload.signed_event.present?, "it is already out there; a second, re-dated copy would be a duplicate"
  end

  def test_the_api_says_when_it_went_back_to_the_signer
    @device_token = ApiToken.issue_device!(@user, name: "Test phone", client_version: "1")
    note = signed_failed_note(signed_at: 1.day.ago)

    api_post "/api/v1/posts/#{note.id}/retry_publish"

    assert_response :success
    assert_equal "awaiting_signature", json.dig("post", "status")
    assert_equal I18n.t("posts.flash.resigning_stale"), json["message"]
  end

  private

  def failed_note(at:)
    @account.posts.create!(
      content: "a plain note", status: :failed, scheduled_at: at,
      unsigned_event: { "kind" => 1, "created_at" => at.to_i, "content" => "a plain note", "tags" => [] },
      publish_results: { "error" => "Signing timed out" }
    )
  end

  def signed_failed_note(signed_at:, results: { "wss://a.example" => "timeout" })
    @account.posts.create!(
      content: "a signed note", status: :failed, scheduled_at: signed_at,
      unsigned_event: { "kind" => 1, "created_at" => signed_at.to_i, "content" => "a signed note", "tags" => [] },
      signed_event: { "id" => "cd" * 32, "created_at" => signed_at.to_i, "sig" => "x" }, event_id: "cd" * 32,
      publish_results: results
    )
  end
end
