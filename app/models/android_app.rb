# frozen_string_literal: true

# What the server knows about the native Android app's releases
# (config/emanator.yml → android).
module AndroidApp
  def self.config = Rails.application.config_for(:emanator)[:android] || {}

  def self.min_version_code = config[:min_version_code].to_i
  def self.latest_version_code = config[:latest_version_code].to_i
  def self.latest_version_name = config[:latest_version_name].to_s
  def self.download_url = config[:download_url]
  def self.zapstore_url = config[:zapstore_url]
  def self.zapstore_published? = zapstore_url.present? && config[:zapstore_published] == true
  def self.github_releases_url = config[:github_releases_url].presence
  def self.obtainium_url = config[:obtainium_url].presence
  # The APK is served from public/android/ (copied there at release time, kept
  # out of git) unless the config points somewhere else.
  def self.apk_filename = "emanator-#{latest_version_name}.apk"
  def self.apk_url
    config[:apk_url].presence || ("/android/#{apk_filename}" if Rails.public_path.join("android", apk_filename).exist?)
  end
  def self.certificate_sha256 = config[:certificate_sha256].presence
  def self.released? = latest_version_code.positive? && apk_url.present?
  # A release exists somewhere (Zapstore, GitHub), even if this server does not
  # host the APK itself.
  def self.published? = latest_version_code.positive?

  def self.release_info
    {
      min_version_code: min_version_code,
      latest_version_code: latest_version_code,
      latest_version_name: latest_version_name,
      download_url: download_url,
      zapstore_url: zapstore_url
    }
  end
end
