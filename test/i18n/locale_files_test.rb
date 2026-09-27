# frozen_string_literal: true

require_relative "../test_helper"

# Every area keeps one file per language (config/locales/<area>/<locale>.yml).
# English is the source; a translation that drifts from it falls back to English
# at runtime without complaint, so the drift is caught here instead.
class LocaleFilesTest < ActiveSupport::TestCase
  LOCALES = %w[sk cs es].freeze
  ROOT = Rails.root.join("config/locales")

  def flatten(hash, prefix = nil)
    hash.each_with_object({}) do |(key, value), out|
      path = [prefix, key].compact.join(".")
      if value.is_a?(Hash) && !plural?(value)
        out.merge!(flatten(value, path))
      else
        out[path] = value
      end
    end
  end

  def plural?(hash)
    hash.keys.any? && (hash.keys.map(&:to_s) - %w[zero one few many other]).empty?
  end

  def keys_in(file, locale)
    data = YAML.safe_load_file(file, aliases: true) || {}
    flatten(data.fetch(locale, {}))
  end

  def interpolations(value)
    Array(value.is_a?(Hash) ? value.values : value).join(" ").scan(/%\{(\w+)\}/).flatten.to_set
  end

  def test_every_area_has_every_language_with_the_same_keys
    Dir[ROOT.join("*/en.yml")].each do |english_file|
      area = File.basename(File.dirname(english_file))
      english = keys_in(english_file, "en")

      LOCALES.each do |locale|
        file = ROOT.join(area, "#{locale}.yml")
        assert File.exist?(file), "#{area}/#{locale}.yml is missing"
        translated = keys_in(file, locale)

        missing = english.keys - translated.keys
        extra = translated.keys - english.keys
        assert_empty missing, "#{area}/#{locale}.yml lacks: #{missing.first(10).join(', ')}"
        assert_empty extra, "#{area}/#{locale}.yml has keys English does not: #{extra.first(10).join(', ')}"

        english.each do |key, value|
          next unless translated.key?(key)
          assert_equal interpolations(value), interpolations(translated[key]),
                       "#{area}/#{locale}.yml #{key} changes the %{…} placeholders"
        end
      end
    end
  end

  # A plural table must hold every form the language's rule (rails-i18n) can
  # pick, or that count raises at render time — the sort of bug that only
  # appears in production, on the day someone has exactly three drafts.
  def test_plural_tables_cover_every_form_the_language_uses
    counts = [ 0, 1, 2, 3, 4, 5, 11, 21, 22, 25, 100 ]

    Dir[ROOT.join("*/en.yml")].each do |english_file|
      area = File.basename(File.dirname(english_file))
      plural_keys = keys_in(english_file, "en").select { |_, v| v.is_a?(Hash) }.keys

      (LOCALES + ["en"]).each do |locale|
        rule = I18n.t("i18n.plural.rule", locale: locale, resolve: false)
        next unless rule.respond_to?(:call)

        translated = keys_in(ROOT.join(area, "#{locale}.yml"), locale)
        plural_keys.each do |key|
          table = translated[key]
          next unless table.is_a?(Hash)

          counts.each do |count|
            form = rule.call(count)
            assert table.key?(form) || table.key?(form.to_s),
                   "#{area}/#{locale}.yml #{key} has no '#{form}' form (needed for #{count})"
          end
        end
      end
    end
  end
end
