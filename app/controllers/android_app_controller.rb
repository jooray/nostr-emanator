# frozen_string_literal: true

# The Android app's download page. Public, so it can be linked from anywhere.
class AndroidAppController < ApplicationController
  skip_before_action :authenticate_user!

  def show
  end
end
