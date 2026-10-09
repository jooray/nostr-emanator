# frozen_string_literal: true

module Api
  module V1
    # Public. The first thing the app asks: which API this is, whether its own
    # build is still supported, and what the server offers (billing, languages).
    class MetaController < BaseController
      skip_before_action :authenticate_device!
      skip_before_action :require_supported_client!

      def show
        render json: {
          api_version: 1,
          name: "Emanator",
          canonical_url: Nostr::AuthService.new.canonical_url,
          locales: I18n.available_locales.map(&:to_s),
          billing_enabled: Billing.enabled?,
          android: AndroidApp.release_info,
          limits: {
            upload_max_bytes: BlossomUpload::MAX_BYTES,
            personality_max_length: Account::MAX_PERSONALITY_LENGTH
          },
          media: {
            max_edges: MediaPreferences::MAX_EDGES,
            photo_formats: MediaPreferences::PHOTO_FORMATS,
            quality_range: [ MediaPreferences::QUALITY_RANGE.min, MediaPreferences::QUALITY_RANGE.max ],
            video_resolutions: MediaPreferences::VIDEO_RESOLUTIONS,
            video_qualities: MediaPreferences::VIDEO_QUALITIES,
            video_bits_per_pixel: MediaPreferences::VIDEO_BITS_PER_PIXEL
          }
        }
      end
    end
  end
end
