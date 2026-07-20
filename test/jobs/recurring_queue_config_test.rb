# frozen_string_literal: true

require "test_helper"

# Regression cover for a schedule that was silently dead from 2026-07-16 to
# 2026-07-20.
#
# In config/recurring.yml, a `class:` entry is enqueued as that job class (so it
# lands on the class's own queue), but a `command:` entry is wrapped in a
# SolidQueue::RecurringJob, which is `queue_as :solid_queue_recurring`. No worker
# listened on that queue, so cleanup_nostr_auth_sessions,
# clear_solid_queue_finished_jobs and the ensure_nip46_supervisor login safety
# net never ran — while EnqueueScheduledPostsJob and SweepStuckRecordsJob kept
# working, which is exactly why nobody noticed. 5,251 jobs had piled up.
class RecurringQueueConfigTest < ActiveSupport::TestCase
  def test_a_worker_listens_on_the_recurring_queue
    assert_includes listened_queues, SolidQueue::RecurringJob.queue_name,
      "no worker consumes #{SolidQueue::RecurringJob.queue_name}, so every " \
      "`command:` entry in recurring.yml will enqueue forever and never run"
  end

  def test_the_normal_queues_are_still_listened_on
    %w[auth signing default].each do |queue|
      assert_includes listened_queues, queue
    end
  end

  # Solid Queue does `Array(options[:queues])`, so a comma-separated *string*
  # becomes a single queue name containing a comma and the worker matches
  # nothing at all. The comma form is only valid as a CLI argument.
  def test_every_worker_declares_its_queues_as_a_list
    workers.each do |worker|
      assert_kind_of Array, worker.fetch("queues"),
        "queues: must be a YAML list, not a comma-separated string"
    end
  end

  private

  def workers
    config = YAML.load(
      ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true
    )
    config.fetch("production").fetch("workers")
  end

  def listened_queues
    workers.flat_map { |w| Array(w.fetch("queues")) }
  end
end
