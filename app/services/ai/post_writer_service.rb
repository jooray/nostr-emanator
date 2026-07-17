# frozen_string_literal: true

module Ai
  class PostWriterService
    def initialize
      @client = Ai::Client.new
    end

    def generate(account:, user_prompt:, language: nil)
      messages = build_messages(account: account, user_prompt: user_prompt, language: language)
      @client.chat(messages: messages, temperature: 0.7, max_tokens: 2000)
    end

    def generate_stream(account:, user_prompt:, language: nil, &block)
      messages = build_messages(account: account, user_prompt: user_prompt, language: language)
      @client.chat_stream(messages: messages, temperature: 0.7, max_tokens: 2000, &block)
    end

    def refine(account:, current_content:, user_prompt:)
      messages = [
        { role: "system", content: refine_system_prompt(account) },
        { role: "user", content: "Here is the current post content:\n\n#{current_content}\n\nPlease apply these changes: #{user_prompt}" }
      ]
      @client.chat(messages: messages, temperature: 0.5, max_tokens: 2000)
    end

    def refine_stream(account:, current_content:, user_prompt:, &block)
      messages = [
        { role: "system", content: refine_system_prompt(account) },
        { role: "user", content: "Here is the current post content:\n\n#{current_content}\n\nPlease apply these changes: #{user_prompt}" }
      ]
      @client.chat_stream(messages: messages, temperature: 0.5, max_tokens: 2000, &block)
    end

    def humanize(content:)
      skill = Ai::SkillLoader.load("humanizer")
      messages = [
        { role: "system", content: skill[:prompt] },
        { role: "user", content: content }
      ]
      @client.chat(messages: messages, temperature: skill[:temperature], max_tokens: skill[:max_tokens])
    end

    def humanize_stream(content:, &block)
      skill = Ai::SkillLoader.load("humanizer")
      messages = [
        { role: "system", content: skill[:prompt] },
        { role: "user", content: content }
      ]
      @client.chat_stream(messages: messages, temperature: skill[:temperature], max_tokens: skill[:max_tokens], &block)
    end

    private

    def build_messages(account:, user_prompt:, language: nil)
      system = generate_system_prompt(account, language)
      [
        { role: "system", content: system },
        { role: "user", content: user_prompt }
      ]
    end

    def generate_system_prompt(account, language = nil)
      prompt = "You are a Nostr post writer. Write short-form text notes (kind 1) for the Nostr social network."
      prompt += "\n\nThe post will be published under the account: #{account.display_name || account.username || account.npub}"

      if account.personality.present?
        prompt += "\n\n## Writing Personality & Style Guide\n#{account.personality}"
      end

      if language.present?
        prompt += "\n\nWrite in #{language}."
      end

      prompt += "\n\n## Rules\n- Output ONLY the post content, no quotes, no explanations\n- Keep it natural and conversational\n- No hashtags unless specifically requested\n- No emojis unless the personality guide says otherwise"

      prompt
    end

    def refine_system_prompt(account)
      prompt = "You are editing a Nostr post. Apply the requested changes while maintaining the post's voice and style."

      if account.personality.present?
        prompt += "\n\n## Account Personality\n#{account.personality}"
      end

      prompt += "\n\nOutput ONLY the revised post content, no explanations."
      prompt
    end
  end
end
