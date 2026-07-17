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

    if params[:timezone].present?
      @user.timezone = params[:timezone]
      @user.save!
      head :ok
      return
    end

    if params[:user] && params[:user].key?(:event_viewer)
      @user.event_viewer = params[:user][:event_viewer]
      @user.save!
      redirect_to edit_user_path, notice: "Event viewer updated."
      return
    end

    if params[:user] && params[:user].key?(:custom_relays)
      @user.custom_relays = params[:user][:custom_relays]
      @user.save!
      redirect_to edit_user_path, notice: "Custom relays updated."
      return
    end

    if @user.update(user_params)
      redirect_to edit_user_path, notice: "Settings updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def user_params
    params.require(:user).permit(:display_name, :username, :about)
  end
end
