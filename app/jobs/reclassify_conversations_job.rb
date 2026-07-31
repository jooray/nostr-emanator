# frozen_string_literal: true

# Re-runs sender classification after the follow or mute graph changed.
#
# Deliberately cache-only (wot: false): this can touch every waiting request at
# once, and running the one-hop web-of-trust query per conversation would be a
# relay fan-out per stranger. New follows are the common case and they are
# answered from the contact-list cache.
class ReclassifyConversationsJob < ApplicationJob
  queue_as :messaging

  discard_on ActiveRecord::RecordNotFound

  def perform(user_id)
    user = User.find(user_id)
    classifier = Messaging::SenderClassifier.new(user, wot: false)

    # Requests may become Known when a follow appears; Known may become muted.
    # Locked rows are skipped inside classify!, so a manual decision is safe.
    user.conversations.active.where(classification: %w[request known]).find_each do |conversation|
      classifier.classify!(conversation)
    end

    Rails.cache.delete(MessagesHelper.unread_cache_key(user))
  end
end
