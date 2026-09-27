# frozen_string_literal: true

require_relative "../test_helper"

class LandingRendersTest < ActionDispatch::IntegrationTest
  def test_the_landing_page_renders_in_english_with_the_language_switcher
    get root_path, headers: { "Accept-Language" => "en" }

    assert_response :success
    assert_select "html[lang=en]"
    assert_select "title", "Emanator - Give every Nostr identity a head start"
    assert_select "h1", "Give every identity a head start."
    assert_select "h1 span.accent-word", "head start."
    assert_select "button.theme-toggle[aria-label=?][data-label-light=?]", "Switch to dark mode", "Switch to light mode"
    assert_select "nav.lang-switch[aria-label=Language]" do
      assert_select "span.lang-active", "English"
      assert_select "form[action=?] button.lang-item", locale_path(locale: "sk"), text: "Slovenčina"
    end
  end
end
