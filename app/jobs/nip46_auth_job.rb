# frozen_string_literal: true

class Nip46AuthJob < ApplicationJob
  queue_as :auth

  def perform(session_id)
    auth_session = NostrAuthSession.active.find_by(session_id: session_id)
    lease_token = auth_session&.claim_listener!
    return unless lease_token

    Rails.logger.info("Starting NIP-46 listener for session #{session_id}")

    heartbeat = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        loop do
          sleep(NostrAuthSession::LISTENER_LEASE / 3)
          break unless auth_session.renew_listener_lease!(lease_token)
        end
      end
    end
    listener = Nostr::Nip46Listener.new(auth_session, lease_token: lease_token)
    pubkey = listener.listen_for_connect

    if pubkey
      Rails.logger.info("NIP-46 auth completed for session #{session_id}, pubkey: #{pubkey}")
    else
      Rails.logger.info("NIP-46 auth timeout or failed for session #{session_id}")
    end
  ensure
    heartbeat&.kill
    heartbeat&.join
    auth_session&.release_listener!(lease_token) if lease_token
  end
end
