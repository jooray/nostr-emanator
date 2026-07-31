# frozen_string_literal: true

# Publishes debounced NIP-RS read-state cursors.
#
# Each publish costs a nip44_encrypt plus a sign_event in the signer, and a
# cursor moves every time a thread is opened — so the debounce is what makes this
# viable rather than a stream of signer prompts.
class FlushReadStatesJob < ApplicationJob
  queue_as :messaging

  def perform
    ReadStateSlot.due_for_publish.includes(:account).find_each do |slot|
      account = slot.account
      next unless account&.messaging_capable?

      Messaging::ReadStateService.new(account).publish!
    rescue StandardError => e
      Rails.logger.warn("Read-state flush failed for account #{slot.account_id}: #{e.message}")
    end
  end
end
