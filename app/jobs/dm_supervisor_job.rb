# frozen_string_literal: true

# Runs the live inbound gift-wrap listener (Nostr::DmSupervisor) as a singleton.
#
# Same shape as Nip46SupervisorJob: a cache lock so a burst of enqueues collapses
# to one runner, and a heartbeat that stops the supervisor promptly if the lock is
# lost — otherwise the lock would expire, a second supervisor would start, and this
# one would keep holding a worker thread until MAX_RUNTIME.
#
# Runs on :dm_supervisor rather than :messaging. It occupies one thread for the
# best part of an hour, and sharing a pool with the decrypt and send jobs would let
# a long backfill starve sending — or, worse, leave no thread free to restart the
# supervisor itself.
class DmSupervisorJob < ApplicationJob
  queue_as :dm_supervisor

  LOCK_KEY = "dm-supervisor-lock"
  LOCK_TTL = 30

  def perform
    token = SecureRandom.hex(16)
    return unless Rails.cache.write(LOCK_KEY, token, unless_exist: true, expires_in: LOCK_TTL)

    Rails.logger.info("DmSupervisorJob acquired lock #{token}")
    supervisor = Nostr::DmSupervisor.new
    heartbeat = start_heartbeat(token, supervisor)
    begin
      supervisor.run
    ensure
      heartbeat.kill
      heartbeat.join
      release_lock(token)
    end
  end

  # Best-effort: the lock is the real guard, this just avoids piling up no-ops.
  def self.ensure_running
    perform_later unless Rails.cache.exist?(LOCK_KEY)
  end

  private

  def start_heartbeat(token, supervisor)
    Thread.new do
      loop do
        sleep(LOCK_TTL / 3)
        unless Rails.cache.read(LOCK_KEY) == token
          Rails.logger.warn("DmSupervisorJob lost lock #{token}; stopping supervisor")
          supervisor.stop!
          break
        end
        Rails.cache.write(LOCK_KEY, token, expires_in: LOCK_TTL)
      end
    rescue StandardError => e
      Rails.logger.warn("DmSupervisorJob heartbeat error: #{e.class} - #{e.message}; stopping supervisor")
      supervisor.stop!
    end
  end

  def release_lock(token)
    Rails.cache.delete(LOCK_KEY) if Rails.cache.read(LOCK_KEY) == token
  end
end
