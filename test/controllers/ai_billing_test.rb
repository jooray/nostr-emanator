# frozen_string_literal: true

require_relative "../test_helper"

# AI assist is the one paid feature on the hosted instance. These tests cover
# the gate in AiAssistController: who gets through, what a denial looks like,
# when the one-time trial starts, and that a self-hosted install (billing off)
# is not affected at all.
class AiBillingTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper
  include BillingTestHelper

  FakeWriter = Struct.new(:calls) do
    def generate(**) = (calls << :generate) && "draft"
    def refine(**) = (calls << :refine) && "refined"
  end

  def setup
    @user = create_signed_in_user
    @account = @user.accounts.create!(
      pubkey_hex: SecureRandom.hex(32), display_name: "Author",
      signer_pubkey: SecureRandom.hex(32), app_privkey: SecureRandom.hex(32), app_pubkey: SecureRandom.hex(32)
    )
    @writer = FakeWriter.new([])
  end

  def with_fake_writer
    original = Ai::PostWriterService.method(:new)
    writer = @writer
    Ai::PostWriterService.singleton_class.send(:define_method, :new) { |*| writer }
    yield
  ensure
    Ai::PostWriterService.singleton_class.send(:define_method, :new) { |*args, **kw, &b| original.call(*args, **kw, &b) }
  end

  def generate(prompt: "Write about privacy", account: @account)
    with_fake_writer { post ai_generate_path, params: { account_id: account.id, prompt: prompt } }
  end

  def test_first_request_starts_the_trial_and_generates
    generate

    assert_response :success
    assert_equal "draft", response.parsed_body["content"]
    assert_equal 1, billing_calls(:start_trial).size
    assert_equal [ :consume, @user.npub, "emanator-ai", "generate", 1, response.request.request_id ],
                 billing_calls(:consume).last.first(6)
  end

  def test_trial_starts_only_once
    generate
    generate
    assert_equal 1, billing_calls(:start_trial).size
  end

  def test_a_blank_prompt_does_not_start_the_trial
    generate(prompt: "")

    assert_response :payment_required
    assert_empty billing_calls(:start_trial)
    assert_empty @writer.calls
  end

  def test_someone_elses_account_does_not_start_the_trial
    other = create_nostr_user.accounts.create!(pubkey_hex: SecureRandom.hex(32), display_name: "Other")
    generate(account: other)

    assert_response :not_found
    assert_empty billing_calls(:start_trial)
  end

  def test_expired_user_gets_a_paywall_and_no_model_call
    @billing.grant(@user.npub, "emanator-ai", 1.day.ago)
    generate

    assert_response :payment_required
    assert_equal "paywall", response.parsed_body["code"]
    assert_equal billing_path, response.parsed_body["billing_url"]
    assert_empty @writer.calls
    assert_empty billing_calls(:consume)
  end

  def test_used_trial_is_not_restarted
    @billing.mark_trial_used(@user.npub, "emanator-ai")
    generate
    assert_response :payment_required
  end

  def test_paid_user_goes_through
    @billing.grant(@user.npub, "all-access", 20.days.from_now)
    with_fake_writer { post ai_refine_path, params: { account_id: @account.id, prompt: "shorter", current_content: "x" } }

    assert_response :success
    assert_equal [ :refine ], @writer.calls
    assert_empty billing_calls(:start_trial)
    assert_equal "refine", billing_calls(:consume).last[3]
  end

  def test_stream_is_denied_with_a_real_status_before_any_sse
    @billing.grant(@user.npub, "emanator-ai", 1.day.ago)
    post ai_generate_stream_path, params: { account_id: @account.id, prompt: "hi" }

    assert_response :payment_required
    assert_equal "application/json", response.media_type
  end

  def test_stream_counts_two_units
    @billing.grant(@user.npub, "emanator-ai", 20.days.from_now)
    service = Object.new
    def service.generate_stream(**) = yield("a")
    def service.humanize_stream(**) = yield("b")
    original = Ai::PostWriterService.method(:new)
    Ai::PostWriterService.singleton_class.send(:define_method, :new) { |*| service }
    post ai_generate_stream_path, params: { account_id: @account.id, prompt: "hi" }

    assert_response :success
    assert_equal 2, billing_calls(:consume).last[4]
  ensure
    Ai::PostWriterService.singleton_class.send(:define_method, :new) { |*args, **kw, &b| original.call(*args, **kw, &b) }
  end

  def test_daily_cap
    @billing.grant(@user.npub, "emanator-ai", 20.days.from_now)
    @billing.consume_allowed = false
    generate

    assert_response :too_many_requests
    assert_equal "daily_cap", response.parsed_body["code"]
    assert_empty @writer.calls
  end

  def test_billing_down_with_nothing_cached_answers_503
    @billing.failure = NostrBilling::Unavailable.new("down")
    generate

    assert_response :service_unavailable
    assert_equal "billing_unavailable", response.parsed_body["code"]
    assert_empty @writer.calls
  end

  def test_billing_down_still_lets_a_known_paying_user_through
    @billing.grant(@user.npub, "emanator-ai", 20.days.from_now)
    generate
    @billing.failure = NostrBilling::Unavailable.new("down")
    travel 2.minutes do
      generate
    end

    assert_response :success
    assert_equal [ :generate, :generate ], @writer.calls
  end

  def test_composer_shows_where_the_user_stands
    get new_account_post_path(@account)
    assert_select "[data-ai-billing-note=none]"

    @billing.grant(@user.npub, "emanator-ai", 20.days.from_now)
    Billing.gate.invalidate(@user.npub)
    get new_account_post_path(@account)
    assert_select "[data-ai-billing-note]", count: 0
  end
end

# Billing off (no BILLING_API_URL): a self-hosted install never sees billing.
class AiWithoutBillingTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  def setup
    @user = create_signed_in_user
    @account = @user.accounts.create!(pubkey_hex: SecureRandom.hex(32), display_name: "Author")
  end

  def test_billing_is_disabled_by_default_in_tests
    refute Billing.enabled?
  end

  def test_no_billing_ui_and_no_billing_pages
    get new_account_post_path(@account)
    assert_response :success
    assert_select "[data-ai-billing-note]", count: 0

    get edit_user_path
    assert_select "#ai-writing", count: 0

    get billing_path
    assert_response :not_found
  end
end
