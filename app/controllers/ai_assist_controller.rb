# frozen_string_literal: true

class AiAssistController < ApplicationController
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
