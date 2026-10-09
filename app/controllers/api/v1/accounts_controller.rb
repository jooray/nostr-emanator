# frozen_string_literal: true

module Api
  module V1
    class AccountsController < BaseController
      before_action :set_account, except: :index

      def index
        accounts = current_user.accounts.order(:created_at).to_a
        render json: { accounts: accounts.map { |a| serializer.account(a, counts: counts_for(accounts)[a.id]) } }
      end

      def show
        upcoming = @account.posts.upcoming.includes(:account, :reposts)
        render json: {
          account: serializer.account(@account, counts: counts_for([ @account ])[@account.id]),
          upcoming: upcoming.map { |p| serializer.post(p) }
        }
      end

      def update
        if @account.update(account_params)
          render json: { account: serializer.account(@account), message: I18n.t("accounts.update.updated") }
        else
          render_error(@account.errors.full_messages.join(", "))
        end
      end

      def destroy
        @account.destroy
        head :no_content
      end

      # H11/M22: the fetches run in the background; the answer says exactly that.
      def refresh_profile
        FetchAccountProfileJob.perform_later(@account.id)
        render json: { ok: true, message: I18n.t("accounts.refresh_profile.notice") }
      end

      def refresh_relays
        FetchRelayListJob.perform_later(@account.id)
        render json: { ok: true, message: I18n.t("accounts.refresh_relays.notice") }
      end

      def recent_events
        events = Rails.cache.fetch("account_events_#{@account.id}", expires_in: 5.minutes) do
          Nostr::EventFetcher.new.fetch(@account.pubkey_hex, kinds: [ 1 ], limit: 20, since: 30.days.ago)
        end
        render json: { events: Array(events).map { |e| serializer.event(e.respond_to?(:stringify_keys) ? e.stringify_keys : e) } }
      rescue StandardError => e
        Rails.logger.warn("Failed to fetch events for account #{@account.id}: #{e.message}")
        render json: { events: [] }
      end

      def recent_interactions
        fetcher = Nostr::InteractionsFetcher.new
        interactions = fetcher.fetch_for_account(@account, since: 7.days.ago, limit: 10)
        fetcher.enrich_with_profiles(interactions)
        fetcher.enrich_with_original_posts(interactions, [ @account ])
        render json: { interactions: interactions.map { |i| serializer.interaction(i) } }
      rescue StandardError => e
        Rails.logger.warn("Failed to fetch interactions for account #{@account.id}: #{e.message}")
        render json: { interactions: [] }
      end

      # The live published profile (kind 0), so editing starts from what is
      # actually out there rather than our cached columns — editing from the
      # cache and publishing would drop every field we do not model.
      def profile
        event = Nostr::ProfileFetcher.new.fetch_raw_event(@account.pubkey_hex)
        fields = event ? JSON.parse(event["content"].to_s) : {}
        pending = @account.profile_updates.order(:created_at).last
        render json: {
          profile: fields.is_a?(Hash) ? fields : {},
          editable_fields: Nostr::ProfilePublisherService::EDITABLE_FIELDS,
          capable: @account.profile_editing_capable?,
          pending: pending && !pending.finished? ? profile_update_json(pending) : nil
        }
      rescue JSON::ParserError, StandardError => e
        Rails.logger.warn("Could not read profile for account #{@account.id}: #{e.class} - #{e.message}")
        render json: { profile: {}, editable_fields: Nostr::ProfilePublisherService::EDITABLE_FIELDS,
                       capable: @account.profile_editing_capable?, pending: nil }
      end

      def update_profile
        return render_error(I18n.t("accounts.update_profile.needs_re_pair"), code: "needs_re_pair") unless @account.profile_editing_capable?

        ProfileUpdate.sweep_stale!
        update = @account.profile_updates.create!(
          user: current_user,
          edits: params.require(:profile).permit(*Nostr::ProfilePublisherService::EDITABLE_FIELDS).to_h,
          status: "pending"
        )
        PublishProfileJob.perform_later(update.id)
        render json: profile_update_json(update), status: :accepted
      end

      def profile_status
        update = @account.profile_updates.find_by(id: params[:update_id])
        return render json: { status: "failed", error: I18n.t("accounts.profile_status.gone") } unless update

        render json: profile_update_json(update)
      end

      private

      def set_account
        @account = current_user.accounts.find(params[:id])
      end

      def account_params
        params.require(:account).permit(:display_name, :username, :about, :picture_url, :personality, :blossom_server)
      end

      # M16: one grouped query per count, not one per account.
      def counts_for(accounts)
        @counts_for ||= begin
          ids = accounts.map(&:id)
          by_status = Post.where(account_id: ids).group(:account_id, :status).count
          upcoming = Post.where(account_id: ids, status: %i[scheduled awaiting_signature])
                         .where("scheduled_at > ?", Time.current).group(:account_id).count
          ids.index_with do |id|
            statuses = by_status.select { |(account_id, _), _| account_id == id }.transform_keys(&:last)
            {
              total: statuses.values.sum,
              draft: statuses["draft"].to_i,
              published: statuses["published"].to_i,
              failed: statuses["failed"].to_i,
              upcoming: upcoming[id].to_i
            }
          end
        end
      end

      def profile_update_json(update)
        { id: update.id, status: update.display_status, step: update.step, error: update.display_error }
      end
    end
  end
end
