# frozen_string_literal: true

module Api
  module V1
    # "Boost as…" for any note on Nostr (web twin: BoostsController).
    class BoostsController < BaseController
      def create
        account = current_user.accounts.find(params[:account_id])
        result = Posts::Boost.event(current_user, account, event_id: params[:event_id].to_s,
                                                           pubkey: params[:pubkey].to_s, kind: params[:kind].presence&.to_i)
        return render_error(result.error) unless result.ok

        render json: { ok: true, message: I18n.t("posts.boost.started", name: account.display_name_or_npub) }
      end
    end
  end
end
