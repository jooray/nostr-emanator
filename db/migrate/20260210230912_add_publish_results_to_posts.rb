class AddPublishResultsToPosts < ActiveRecord::Migration[8.1]
  def change
    add_column :posts, :publish_results, :json
    add_column :reposts, :publish_results, :json
  end
end
