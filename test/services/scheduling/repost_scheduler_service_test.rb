# frozen_string_literal: true

require_relative "../../jobs/job_test_helper"

class RepostSchedulerServiceTest < ActiveSupport::TestCase
  include JobTestHelper

  def setup
    @post = build_post(status: :draft, scheduled_at: 1.hour.from_now)
    @other = @post.account.user.accounts.create!(pubkey_hex: SecureRandom.hex(32))
    @service = Scheduling::RepostSchedulerService.new
  end

  def test_schedules_a_repost_after_the_original
    reposts = @service.schedule_reposts(@post, [@other.id], max_delay_hours: 2)

    assert_equal 1, reposts.size
    assert reposts.first.scheduled_at > @post.scheduled_at
    assert_equal "pending_signature", reposts.first.status
  end

  # L11: max_delay_hours = 0 used to produce rand(10..0) => nil => NoMethodError.
  def test_zero_max_delay_is_clamped_instead_of_blowing_up
    reposts = @service.schedule_reposts(@post, [@other.id], max_delay_hours: 0)

    assert_equal 1, reposts.size
    assert reposts.first.delay_minutes >= Scheduling::RepostSchedulerService::MIN_DELAY_MINUTES
  end

  def test_absurd_max_delay_is_clamped_to_one_year
    reposts = @service.schedule_reposts(@post, [@other.id], max_delay_hours: 10_000_000)

    assert reposts.first.scheduled_at <= @post.scheduled_at + Scheduling::RepostSchedulerService::MAX_DELAY_HOURS.hours
  end

  # L11: nil scheduled_at used to raise NoMethodError deep inside the loop.
  def test_missing_scheduled_at_raises_a_clear_error
    @post.update_column(:scheduled_at, nil)

    error = assert_raises(ArgumentError) { @service.schedule_reposts(@post.reload, [@other.id]) }
    assert_match(/scheduled_at/, error.message)
  end

  def test_rescheduling_the_same_account_is_idempotent
    @service.schedule_reposts(@post, [@other.id], max_delay_hours: 2)
    @service.schedule_reposts(@post, [@other.id], max_delay_hours: 2)

    assert_equal 1, @post.reposts.count
  end

  def test_accounts_of_other_users_are_ignored
    foreign = build_account

    assert_empty @service.schedule_reposts(@post, [foreign.id], max_delay_hours: 2)
  end
end
