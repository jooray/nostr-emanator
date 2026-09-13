# frozen_string_literal: true

# Delivery is a poll of N stations, not a boolean.
#
# `publish_results` is a `{relay_url => "ok" | <error string>}` hash written by
# EventPublisherService. Before this concern existed, every surface in the app
# read `status` instead: one relay out of six accepting set the record to
# `published`, which rendered as a green tick and the same badge as a 6/6
# delivery. A note that effectively did not ship was reported as a success.
#
# Nothing here decides presentation — it only answers "how many of the relays we
# sent to actually took it", so that the badge, the dashboard count and the
# nav indicator can all agree.
module RelayDelivery
  extend ActiveSupport::Concern

  included do
    # Records whose delivery fell short of the relays they were sent to. Used by
    # the dashboard alarm block and the failure count in the nav.
    scope :short_delivery, -> { where(status: :published).select(&:delivery_alarming?) }
  end

  def delivery_results
    publish_results.presence || {}
  end

  def delivery_total
    delivery_results.size
  end

  def delivery_ok_count
    delivery_results.values.count { |v| v.to_s == "ok" }
  end

  def delivery_failures
    delivery_results.reject { |_relay, result| result.to_s == "ok" }
  end

  # A relay declining is ordinary. Nostr is a gossip network: every client
  # publishes to more relays than it needs precisely because individual relays
  # rate-limit, go down, or refuse. 5 of 6 is a successful publish, and treating
  # it as a failure teaches the operator to ignore the alarm — which is the one
  # thing an alarm cannot survive.
  #
  # So the grades separate "not everything took" (information) from "this did
  # not actually reach the network" (an alarm):
  #
  #   :all     every relay accepted
  #   :partial some declined, but the note is out there — nominal
  #   :thin    exactly one relay accepted out of four or more — effectively
  #            invisible, and one outage from being gone
  #   :none    nothing accepted it
  #
  # :unknown until a publish has been attempted — an unsent post has no delivery
  # to grade and must not read as a failure.
  THIN_DELIVERY_FLOOR = 4

  def delivery_grade
    return :unknown if delivery_total.zero?
    return :none if delivery_ok_count.zero?
    return :all if delivery_ok_count == delivery_total
    return :thin if delivery_ok_count == 1 && delivery_total >= THIN_DELIVERY_FLOOR

    :partial
  end

  # Did it reach fewer relays than it was sent to? Factual, and worth showing as
  # a tally — but on its own it is NOT a reason to raise anything.
  def delivery_short?
    return false unless respond_to?(:published?) && published?

    %i[partial thin none].include?(delivery_grade)
  end

  # The only delivery condition that earns the operator's attention: the note
  # is effectively not on the network.
  def delivery_alarming?
    return false unless respond_to?(:published?) && published?

    %i[thin none].include?(delivery_grade)
  end

  # "5/6" — the thing that belongs next to the word "Published" everywhere it
  # appears. nil when there is nothing to count yet.
  def delivery_tally
    return nil if delivery_total.zero?

    "#{delivery_ok_count}/#{delivery_total}"
  end
end
