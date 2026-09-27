# frozen_string_literal: true

require_relative "../test_helper"

class LocaleSelectionTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  def test_a_visitor_gets_the_language_their_browser_asks_for
    get root_path, headers: { "Accept-Language" => "sk-SK,sk;q=0.9,en;q=0.5" }

    assert_select "html[lang=sk]"
  end

  def test_an_unsupported_browser_language_falls_back_to_english
    get root_path, headers: { "Accept-Language" => "de-DE" }

    assert_select "html[lang=en]"
  end

  def test_the_switcher_overrides_the_browser_for_a_visitor
    post locale_path(locale: "es")
    get root_path, headers: { "Accept-Language" => "sk" }

    assert_select "html[lang=es]"
  end

  def test_the_switcher_saves_the_choice_on_the_signed_in_user
    user = create_signed_in_user
    post locale_path(locale: "cs")

    assert_equal "cs", user.reload.locale
  end

  def test_an_unknown_locale_is_ignored
    user = create_signed_in_user
    post locale_path(locale: "cs")
    post locale_path(locale: "xx")

    assert_equal "cs", user.reload.locale
  end

  def test_a_user_without_a_choice_gets_their_browser_language_recorded
    user = create_signed_in_user
    user.reload.update!(settings: user.settings.except("locale"))
    get edit_user_path, headers: { "Accept-Language" => "es-ES" }

    assert_equal "es", user.reload.locale
  end
end
