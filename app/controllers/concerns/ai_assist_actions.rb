# frozen_string_literal: true

# The AI writing actions, shared by the web composer (AiAssistController) and
# the native app (Api::V1::AiAssistController) so both get the same prompts, the
# same gate and the same stream format.
#
# Streams are real: ActionController::Live hands every chunk to the client as the
# model produces it. Without Live, Rails buffered the whole SSE body and the
# composer's "streaming" preview only ever appeared at the very end.
#
# Callback order is deliberate, see RequireAiEntitlement: entitlement, then the
# hourly rate limits, then the daily units.
module AiAssistActions
  extend ActiveSupport::Concern

  # H5: these actions burn paid Venice API credits and pin a thread for up to
  # ~300s (streams do 2 upstream calls each). Cap per-user usage so a script, a
  # crafted link, or a runaway client can't rack up unbounded cost/thread
  # pressure. Generous for normal composing, but bound the worst case.
  GENERATE_RATE_LIMIT = 20
  REFINE_RATE_LIMIT = 40

  included do
    include ActionController::Live
    include RequireAiEntitlement

    before_action :require_ai_entitlement!
    rate_limit to: GENERATE_RATE_LIMIT, within: 1.hour, only: [ :generate, :generate_stream ],
               by: -> { current_user&.id || request.remote_ip }, with: :ai_rate_limited
    rate_limit to: REFINE_RATE_LIMIT, within: 1.hour, only: [ :refine, :refine_stream ],
               by: -> { current_user&.id || request.remote_ip }, with: :ai_rate_limited
    before_action :consume_ai_units!
  end

  def generate
    content = Ai::PostWriterService.new.generate(account: ai_account, user_prompt: params[:prompt], language: params[:language])
    render json: { content: content }
  rescue Ai::Client::ApiError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def generate_stream
    account = ai_account
    stream_sse do |sse, service|
      sse.write({ phase: "generating" }, event: "phase")
      draft = stream_chunks(sse) { |&blk| service.generate_stream(account: account, user_prompt: params[:prompt], language: params[:language], &blk) }

      sse.write({ phase: "humanizing" }, event: "phase")
      stream_chunks(sse) { |&blk| service.humanize_stream(content: draft, &blk) }
    end
  end

  def refine
    content = Ai::PostWriterService.new.refine(account: ai_account, current_content: params[:current_content], user_prompt: params[:prompt])
    render json: { content: content }
  rescue Ai::Client::ApiError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def refine_stream
    account = ai_account
    stream_sse do |sse, service|
      sse.write({ phase: "refining" }, event: "phase")
      refined = stream_chunks(sse) { |&blk| service.refine_stream(account: account, current_content: params[:current_content], user_prompt: params[:user_prompt], &blk) }

      sse.write({ phase: "humanizing" }, event: "phase")
      stream_chunks(sse) { |&blk| service.humanize_stream(content: refined, &blk) }
    end
  end

  private

  def ai_account
    current_user.accounts.find(params[:account_id])
  end

  def sse_headers!
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
    # Rack::ETag would otherwise buffer the body to hash it.
    response.headers["Last-Modified"] = Time.now.httpdate
  end

  # The block streams; whatever its last stage returns is the final text.
  def stream_sse
    sse_headers!
    sse = SSE.new(response.stream)
    final = yield(sse, Ai::PostWriterService.new)
    sse.write({ content: final }, event: "complete")
  rescue ActionController::Live::ClientDisconnected, IOError
    nil
  rescue => e
    sse.write({ message: e.message }, event: "error")
  ensure
    sse&.close
  end

  # Runs one streaming model call, forwarding each chunk to the client, and
  # returns the accumulated text. `producer` receives the per-chunk callback.
  def stream_chunks(sse, &producer)
    text = +""
    producer.call do |chunk|
      text << chunk
      sse.write(chunk.to_json, event: "chunk")
    end
    text
  end

  # Shared by both rate limiters (via `with:`). Streams need an SSE-shaped
  # response (the client is mid-fetch expecting `event:`/`data:` frames);
  # the plain JSON actions get a normal 429.
  def ai_rate_limited
    message = t("ai_assist.rate_limited")

    if action_name.end_with?("_stream")
      sse_headers!
      sse = SSE.new(response.stream)
      sse.write({ message: message }, event: "error")
      sse.close
    else
      render json: { error: message }, status: :too_many_requests
    end
  end

  class SSE
    def initialize(stream)
      @stream = stream
    end

    def write(data, event: nil)
      @stream.write("event: #{event}\n") if event
      @stream.write("data: #{data.is_a?(String) ? data : data.to_json}\n\n")
    end

    def close
      @stream.close
    rescue IOError
    end
  end
end
