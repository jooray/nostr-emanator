# frozen_string_literal: true

# The language switcher. POST so a crawler following links cannot flip a
# signed-in user's setting; the cookie covers visitors with no account yet.
class LocalesController < ApplicationController
  skip_before_action :authenticate_user!

  def update
    locale = params[:locale].to_s
    if I18n.available_locales.map(&:to_s).include?(locale)
      cookies.permanent[LOCALE_COOKIE] = { value: locale, same_site: :lax }
      if user_signed_in?
        current_user.locale = locale
        current_user.save!
      end
    end

    redirect_back fallback_location: root_path
  end
end
