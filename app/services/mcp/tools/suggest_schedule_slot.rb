# frozen_string_literal: true

module Mcp
  module Tools
    class SuggestScheduleSlot < Base
      def self.description
        "Suggest the next free posting slot for one of the user's accounts, using " \
          "the same smart-scheduling logic as the app (spreads posts across days at " \
          "a random daytime hour in the user's timezone). Useful before create_draft_post."
      end

      def self.input_schema
        {
          type: "object",
          additionalProperties: false,
          required: ["account_id"],
          properties: {
            account_id: { type: "integer" }
          }
        }
      end

      def call
        account = find_user_account!(args[:account_id])
        timezone = user.timezone
        slot = Scheduling::SchedulerService.new(timezone: timezone).suggest_next_slot(account)

        {
          account_id: account.id,
          timezone: timezone,
          suggested_slot: slot.iso8601
        }
      end
    end
  end
end
