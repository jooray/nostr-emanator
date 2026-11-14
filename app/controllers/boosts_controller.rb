# frozen_string_literal: true

# "Boost as…" for any note on Nostr, from the account page.
class BoostsController < ApplicationController
  def create
    account = current_user.accounts.find(params[:account_id])
    result = Posts::Boost.event(current_user, account, event_id: params[:event_id].to_s,
                                                       pubkey: params[:pubkey].to_s, kind: params[:kind].presence&.to_i)
    message = result.ok ? t("posts.boost.started", name: account.display_name_or_npub) : result.error
    redirect_back fallback_location: account_path(account), (result.ok ? :notice : :alert) => message
  end
end
