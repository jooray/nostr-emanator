# frozen_string_literal: true

# Requeues gift wraps left mid-decrypt by a worker that died — a deploy restart,
# a killed process, a signer session that hung past its deadline.
#
# Without this a wrap claimed by a dead job stays `decrypting` forever and its
# message never appears, with nothing in the UI explaining why.
class SweepStuckGiftWrapsJob < ApplicationJob
  queue_as :messaging

  def perform
    swept = 0

    GiftWrap.stuck.find_each do |wrap|
      # transition_status, not update!, so a worker that is actually still alive
      # and about to finish this wrap wins the race instead of being stomped.
      next unless wrap.transition_status(from: :decrypting, to: :pending)

      wrap.increment!(:attempts)
      wrap.update!(last_error: "decryption did not finish; requeued") if wrap.attempts < GiftWrap::MAX_ATTEMPTS
      wrap.update!(status: "undecryptable", last_error: "decryption never completed") if wrap.attempts >= GiftWrap::MAX_ATTEMPTS
      swept += 1
    end

    Rails.logger.info("Requeued #{swept} stuck gift wrap(s)") if swept.positive?
    swept
  end
end
