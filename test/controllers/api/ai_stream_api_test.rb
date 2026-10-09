# frozen_string_literal: true

require_relative "../../test_helper"

# The app streams AI drafts through the same actions as the web composer.
class AiStreamApiTest < ActionDispatch::IntegrationTest
  include ApiTestHelper

  def setup
    @user = create_api_user
    @account = create_signed_account(@user)
  end

  def test_stream_sends_chunks_then_complete
    service = Object.new
    def service.generate_stream(**) = (yield("Hel") && yield("lo"))
    def service.humanize_stream(**) = yield("Hello!")

    override(Ai::PostWriterService, :new, service) do
      api_post "/api/v1/ai/generate_stream", params: { account_id: @account.id, prompt: "greet" }
    end

    assert_response :success
    assert_equal "text/event-stream", response.media_type
    assert_includes response.body, "event: chunk\ndata: \"Hel\""
    assert_includes response.body, "event: complete\ndata: {\"content\":\"Hello!\"}"
  end
end
