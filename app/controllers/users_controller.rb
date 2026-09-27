# frozen_string_literal: true

class UsersController < ApplicationController
  def edit
    @user = current_user
  end

  def update
    @user = current_user

    if params[:theme].present?
      @user.theme = params[:theme]
      @user.save!
      head :ok
      return
    end

    if params[:locale].present?
      @user.locale = params[:locale]
      @user.save!
      cookies.permanent[LOCALE_COOKIE] = @user.locale if @user.locale
      I18n.locale = @user.locale || I18n.locale
      redirect_to edit_user_path, notice: t("users.update.language_updated")
      return
    end

    if params[:timezone].present?
      @user.timezone = params[:timezone]
      @user.save!
      head :ok
      return
    end

    if params[:user] && params[:user].key?(:event_viewer)
      @user.event_viewer = params[:user][:event_viewer]
      @user.save!
      redirect_to edit_user_path, notice: t(".event_viewer_updated")
      return
    end

    if params[:user] && params[:user].key?(:custom_relays)
      @user.custom_relays = params[:user][:custom_relays]
      # H4: unsafe relay URLs are rejected by the model — show why.
      if @user.save
        redirect_to edit_user_path, notice: t(".custom_relays_updated")
      else
        redirect_to edit_user_path, alert: @user.errors.full_messages.join(" ")
      end
      return
    end

    if @user.update(user_params)
      redirect_to edit_user_path, notice: t(".settings_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def user_params
    params.require(:user).permit(:display_name, :username, :about)
  end
end
