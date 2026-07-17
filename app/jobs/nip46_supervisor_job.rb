# frozen_string_literal: true

# Runs the multiplexed NIP-46 listener that serves ALL pending logins/pairings at
# once (see Nostr::Nip46Supervisor). Enqueued whenever a login or pairing session
# is created, plus a recurring safety-net (config/recurring.yml) that restarts it
# if pending sessions exist but no supervisor is running (e.g. after a deploy).
#
# A cache-based singleton lock keeps exactly one supervisor alive at a time, so a
# burst of enqueues (or an overlapping recurring tick) collapses to one runner.
class Nip46SupervisorJob < ApplicationJob
  queue_as :auth

  LOCK_KEY = "nip46-supervisor-lock"
  LOCK_TTL = 30 # seconds; renewed by the heartbeat while the supervisor runs

  def perform
    token = SecureRandom.hex(16)
    return unless Rails.cache.write(LOCK_KEY, token, unless_exist: true, expires_in: LOCK_TTL)

    Rails.logger.info("Nip46SupervisorJob acquired lock #{token}")
    heartbeat = start_heartbeat(token)
    begin
      Nostr::Nip46Supervisor.new.run
    ensure
      heartbeat.kill
      heartbeat.join
      release_lock(token)
    end
  end

  # Enqueue a supervisor unless one is already running (best-effort: the job's own
  # lock is the real guard, this just avoids piling up no-op jobs).
  def self.ensure_running
    perform_later unless Rails.cache.exist?(LOCK_KEY)
  end

  private

  # Keep the singleton lock fresh while we run, and stop the supervisor promptly
  # if the lock is lost (e.g. another process took over).
  def start_heartbeat(token)
    Thread.new do
      loop do
        sleep(LOCK_TTL / 3)
        break unless Rails.cache.read(LOCK_KEY) == token
        Rails.cache.write(LOCK_KEY, token, expires_in: LOCK_TTL)
      end
    rescue => e
      Rails.logger.warn("Nip46SupervisorJob heartbeat error: #{e.class} - #{e.message}")
    end
  end

  def release_lock(token)
    Rails.cache.delete(LOCK_KEY) if Rails.cache.read(LOCK_KEY) == token
  end
end
