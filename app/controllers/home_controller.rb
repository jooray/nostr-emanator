# frozen_string_literal: true

# Public marketing landing page served at "/". Signed-in users are sent
# straight to their dashboard; everyone else sees the landing page, whose
# "Launch app" buttons point at /auth/nostr.
class HomeController < ApplicationController
  skip_before_action :authenticate_user!, only: :index

  def index
    redirect_to dashboard_path if user_signed_in?
    # Otherwise render app/views/home/index.html.erb (no app chrome).
  end

  layout false
end
