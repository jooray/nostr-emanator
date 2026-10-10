# frozen_string_literal: true

# Public marketing landing page served at "/". Signed-in users are sent
# straight to their dashboard; everyone else sees the landing page, whose
# "Launch app" buttons point at /auth/nostr.
class HomeController < ApplicationController
  skip_before_action :authenticate_user!, only: :index

  def index
    return redirect_to dashboard_path if user_signed_in?

    # The #install section leads with the native app for Android visitors and
    # with the installable web app for everyone else. The page varies by user
    # agent, so no shared cache may hand one variant to the other.
    @android_visitor = request.user_agent.to_s.match?(/Android/i)
    response.headers["Vary"] = [response.headers["Vary"], "User-Agent"].compact_blank.join(", ")
    # Render app/views/home/index.html.erb (no app chrome).
  end

  layout false
end
