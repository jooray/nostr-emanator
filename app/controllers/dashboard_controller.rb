# frozen_string_literal: true

class DashboardController < ApplicationController
  def index
    @accounts_count = current_user.accounts.count
    @posts_count = Post.joins(:account).where(accounts: { user_id: current_user.id }).count
    @scheduled_count = Post.joins(:account).where(accounts: { user_id: current_user.id }).where(status: :scheduled).count
    @published_count = Post.joins(:account).where(accounts: { user_id: current_user.id }).where(status: :published).count

    @upcoming_posts = Post.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .where(status: [:scheduled, :awaiting_signature])
      .where("posts.scheduled_at > ?", Time.current)
      .includes(:account, :reposts)
      .order("posts.scheduled_at ASC")
      .limit(10)

    @failed_posts = Post.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .where(status: :failed)
      .includes(:account)
      .order(updated_at: :desc)
      .limit(5)
  end
end
