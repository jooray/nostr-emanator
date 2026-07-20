# frozen_string_literal: true

class AiAssistController < ApplicationController
  # H5: these actions burn paid Venice API credits and pin a Puma thread for up
  # to ~300s (streams do 2 upstream calls each). Cap per-user usage so a script,
  # a crafted link, or a runaway client can't rack up unbounded cost/thread
  # pressure. Numbers are generous for normal composing (a handful of drafts
  # per session) but bound the worst case.
  GENERATE_RATE_LIMIT = 20
  REFINE_RATE_LIMIT = 40

  rate_limit to: GENERATE_RATE_LIMIT, within: 1.hour, only: [ :generate, :generate_stream ],
             by: -> { current_user&.id || request.remote_ip }, with: :ai_rate_limited
  rate_limit to: REFINE_RATE_LIMIT, within: 1.hour, only: [ :refine, :refine_stream ],
             by: -> { current_user&.id || request.remote_ip }, with: :ai_rate_limited

  def generate
    account = current_user.accounts.find(params[:account_id])
    user_prompt = params[:prompt]

    service = Ai::PostWriterService.new
    content = service.generate(account: account, user_prompt: user_prompt, language: params[:language])

    render json: { content: content }
  rescue Ai::Client::ApiError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def generate_stream
    account = current_user.accounts.find(params[:account_id])
    user_prompt = params[:prompt]

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    service = Ai::PostWriterService.new

    sse = SSE.new(response.stream)

    begin
      sse.write({ phase: "generating" }, event: "phase")

      generated_content = ""
      service.generate_stream(account: account, user_prompt: user_prompt, language: params[:language]) do |chunk|
        generated_content += chunk
        sse.write(chunk.to_json, event: "chunk")
      end

      # Humanize
      sse.write({ phase: "humanizing" }, event: "phase")

      humanized_content = ""
      service.humanize_stream(content: generated_content) do |chunk|
        humanized_content += chunk
        sse.write(chunk.to_json, event: "chunk")
      end

      sse.write({ content: humanized_content }, event: "complete")
    rescue => e
      sse.write({ message: e.message }, event: "error")
    ensure
      sse.close
    end
  end

  def refine
    account = current_user.accounts.find(params[:account_id])
    current_content = params[:current_content]
    user_prompt = params[:prompt]

    service = Ai::PostWriterService.new
    content = service.refine(account: account, current_content: current_content, user_prompt: user_prompt)

    render json: { content: content }
  rescue Ai::Client::ApiError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def refine_stream
    account = current_user.accounts.find(params[:account_id])
    current_content = params[:current_content]
    user_prompt = params[:user_prompt]

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    service = Ai::PostWriterService.new

    sse = SSE.new(response.stream)

    begin
      sse.write({ phase: "refining" }, event: "phase")

      refined_content = ""
      service.refine_stream(account: account, current_content: current_content, user_prompt: user_prompt) do |chunk|
        refined_content += chunk
        sse.write(chunk.to_json, event: "chunk")
      end

      sse.write({ phase: "humanizing" }, event: "phase")

      humanized_content = ""
      service.humanize_stream(content: refined_content) do |chunk|
        humanized_content += chunk
        sse.write(chunk.to_json, event: "chunk")
      end

      sse.write({ content: humanized_content }, event: "complete")
    rescue => e
      sse.write({ message: e.message }, event: "error")
    ensure
      sse.close
    end
  end

  private

  # Shared by both rate limiters (via `with:`). Streams need an SSE-shaped
  # response (the client is mid-fetch expecting `event:`/`data:` frames);
  # the plain JSON actions get a normal 429.
  def ai_rate_limited
    message = "AI request limit reached — please wait a bit before trying again."

    if action_name.end_with?("_stream")
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"
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
