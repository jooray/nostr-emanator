# frozen_string_literal: true

module Messaging
  # Which accounts' conversations the inbox shows. Server-side, not the
  # client-side pill filter the interactions page uses: hiding rows in the DOM
  # interacts badly with pagination (short and empty pages). Persisted on the
  # user, so the web and the app show the same inbox.
  class AccountFilter
    SETTING = "dm_account_filter"

    def initialize(user, accounts)
      @user = user
      @accounts = accounts
    end

    # `requested` is the raw parameter, or nil when the request did not set one
    # (then the saved choice applies). Empty is the canonical "every account".
    def resolve(requested)
      unless requested.nil?
        ids = normalize(Array(requested).reject(&:blank?).map(&:to_i))
        @user.update_column(:settings, (@user.settings || {}).merge(SETTING => ids))
        return ids
      end

      normalize(Array(@user.settings&.dig(SETTING)).map(&:to_i))
    end

    private

    # Selecting all of them by hand must collapse to the same thing as none, or
    # the UI would show a "Select all" link next to a set that is already all.
    def normalize(ids)
      all = @accounts.map(&:id)
      ids &= all
      ids.sort == all.sort ? [] : ids
    end
  end
end
