# frozen_string_literal: true

require_relative "../test_helper"

# The calendar and a post's own detail page disagreed about what time a post goes
# out: the cell said 08:00 and the page said 10:00 AM, two hours apart, because
# the cell was formatted in the server's UTC and the page was converted to the
# browser's zone in JS. A scheduling product that prints two different release
# times for the same post is not usable, so both halves are pinned here.
class CalendarTimezoneTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  ZONE = "Europe/Bratislava" # UTC+2 in September

  def setup
    @user = create_signed_in_user
    @user.timezone = ZONE
    @user.save!
    @account = paired_account
  end

  def test_calendar_prints_the_release_hour_in_the_users_zone
    # 08:00 UTC is 10:00 in Bratislava. The cell must say 10:00.
    scheduled_post(Time.utc(2026, 9, 14, 8, 0))

    get calendar_path(month: "2026-09-01")

    assert_response :success
    assert_match(/10:00/, response.body, "calendar should print the hour in the user's zone")
    assert_no_match(/>08:00</, response.body, "calendar must not print the server's UTC hour")
  end

  def test_calendar_and_post_page_agree_on_the_hour
    post = scheduled_post(Time.utc(2026, 9, 14, 8, 0))

    get calendar_path(month: "2026-09-01")
    calendar_hours = response.body.scan(/(\d{2}:\d{2})/).flatten

    get post_path(post)
    detail = response.body

    assert_includes calendar_hours, "10:00"
    assert_match(/10:00/, detail, "the detail page and the calendar must name the same hour")
  end

  # A bare `start_date..end_date` against a datetime column casts both ends to
  # midnight, so anything after 00:00 on the grid's final day fell outside the
  # query and that cell rendered empty however much was scheduled in it.
  def test_the_last_day_of_the_grid_still_shows_its_events
    # September 2026 ends on a Wednesday, so the grid runs through Sunday Oct 4.
    last_day = Date.new(2026, 9, 1).end_of_month.end_of_week(:monday)
    post = scheduled_post(Time.find_zone!(ZONE).local(last_day.year, last_day.month, last_day.day, 18, 30))

    get calendar_path(month: "2026-09-01")

    assert_response :success
    assert_match(/18:30/, response.body,
                 "an event on #{last_day} — the last cell of the grid — must appear")
    assert_match(/#{post.id}/, response.body)
  end

  # Near midnight the zone decides which cell an event belongs in: 23:30 local on
  # the 14th is 21:30 UTC the same day, but 00:30 local on the 15th is 22:30 UTC
  # on the 14th — and bucketing that in UTC files it under the wrong day.
  def test_an_event_just_after_midnight_lands_on_its_local_day
    post = scheduled_post(Time.find_zone!(ZONE).local(2026, 9, 15, 0, 30))

    get calendar_path(month: "2026-09-01")

    assert_response :success
    cells = response.body.split(%r{min-h-\[132px\]})
    owning_cell = cells.find { |cell| cell.include?(post_path(post)) }

    assert owning_cell, "the post should be rendered in some cell"
    assert_match(/>\s*15\s*</, owning_cell, "00:30 on the 15th belongs to the 15th, not the 14th")
  end

  def test_a_user_with_no_stored_zone_still_renders
    @user.timezone = nil
    @user.save!
    scheduled_post(Time.utc(2026, 9, 14, 8, 0))

    get calendar_path(month: "2026-09-01")

    assert_response :success
  end

  private

  def scheduled_post(at)
    @account.posts.create!(content: "Release check", status: "scheduled", scheduled_at: at)
  end

  def paired_account(**attrs)
    @user.accounts.create!({
      pubkey_hex: SecureRandom.hex(32),
      display_name: "Paired",
      signer_pubkey: SecureRandom.hex(32),
      app_privkey: SecureRandom.hex(32),
      app_pubkey: SecureRandom.hex(32)
    }.merge(attrs))
  end
end
