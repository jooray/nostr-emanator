# frozen_string_literal: true

module Ai
  class SkillLoader
    class SkillNotFoundError < StandardError; end
    class SkillParseError < StandardError; end

    SKILLS_PATH = Rails.root.join("app", "skills")

    class << self
      def load(skill_name)
        cache[skill_name] ||= parse_skill_file(skill_name)
      end

      def reload!(skill_name = nil)
        if skill_name
          cache.delete(skill_name)
        else
          @cache = {}
        end
      end

      private

      def cache
        @cache ||= {}
      end

      def parse_skill_file(skill_name)
        file_path = SKILLS_PATH.join(skill_name, "SKILL.md")

        unless File.exist?(file_path)
          raise SkillNotFoundError, "Skill file not found: #{file_path}"
        end

        content = File.read(file_path)
        frontmatter, prompt = extract_frontmatter(content)

        {
          name: frontmatter["name"] || skill_name,
          version: frontmatter["version"],
          description: frontmatter["description"],
          temperature: frontmatter["temperature"]&.to_f || 0.7,
          max_tokens: frontmatter["max_tokens"]&.to_i || 4000,
          frontmatter: frontmatter,
          prompt: prompt.strip
        }
      end

      def extract_frontmatter(content)
        if content.start_with?("---")
          parts = content.split("---", 3)
          if parts.length >= 3
            frontmatter = YAML.safe_load(parts[1]) || {}
            prompt = parts[2]
            return [frontmatter, prompt]
          end
        end

        [{}, content]
      rescue Psych::SyntaxError => e
        raise SkillParseError, "Failed to parse YAML frontmatter: #{e.message}"
      end
    end
  end
end
