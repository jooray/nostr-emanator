# frozen_string_literal: true

module Api
  module V1
    # Media for the composer. The app has already shrunk and stripped the
    # file on the phone (see MediaPreferences); here it goes through the same
    # intake as the web upload, and the same background job signs and PUTs it.
    class UploadsController < BaseController
      rate_limit to: 20, within: 1.minute, by: -> { current_user&.id || request.remote_ip },
                 only: :create, with: :rate_limited

      def create
        account = current_user.accounts.find(params[:account_id])
        result = BlossomUploadIntake.new(current_user, account).accept(params[:file])
        return render_error(result.error, status: result.status) unless result.ok?

        render json: serializer.upload(result.upload), status: :accepted
      end

      def show
        upload = BlossomUpload.where(user_id: current_user.id).find(params[:id])
        render json: serializer.upload(upload.fail_if_stuck!)
      end

      private

      def rate_limited
        render_error(I18n.t("blossom_uploads.errors.rate_limited"), status: :too_many_requests, code: "rate_limited")
      end
    end
  end
end
