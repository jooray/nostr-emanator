# frozen_string_literal: true

module Messaging
  # Nudges anyone watching a conversation to re-fetch it.
  #
  # Both halves of messaging are asynchronous — a send waits on human approvals in
  # the signer, and inbound messages arrive whenever the decrypt job gets to them
  # — so without this the only way to see either was to reload the page.
  #
  # Deliberately a bare Turbo refresh signal, never rendered content. The cable
  # adapter is Solid Cable, which persists every broadcast payload to the cable
  # database for a day — broadcasting rendered bubbles would store decrypted
  # message bodies in plaintext right next to the `encrypts`-protected messages
  # table. A refresh signal carries nothing; the subscribed page re-fetches the
  # thread over HTTPS with the viewer's own session, and Turbo morphs the result
  # in place (see show.html.erb), so scroll position and a half-typed reply
  # survive. It also makes a burst of ingested messages cheap: the payload is
  # constant-size and Turbo coalesces refreshes client-side.
  class ThreadBroadcaster
    def self.refresh(conversation)
      Turbo::StreamsChannel.broadcast_refresh_to(conversation)
    rescue StandardError => e
      # A broadcast failure must never fail the send or the ingest that
      # triggered it — the message is already saved, this is only the view.
      Rails.logger.warn("Could not broadcast thread #{conversation&.id}: #{e.class} - #{e.message}")
    end
  end
end
