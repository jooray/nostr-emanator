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

  def test_the_header_has_the_pricing_link_and_a_language_menu
    get root_path, headers: { "Accept-Language" => "sk" }

    assert_select "header.site-header" do
      assert_select "a.nav-link[href='#pricing']"
      assert_select "details.lang-menu summary .lang-code", "SK"
      assert_select "details.lang-menu form[action=?] button.lang-item", locale_path(locale: "en")
    end
  end

  def test_pricing_shows_the_free_tier_ai_writing_and_the_bundle
    get root_path, headers: { "Accept-Language" => "en" }

    assert_select "section#pricing" do |section|
      text = section.text
      assert_match "10,000 sats", text
      assert_match "25,000 sats", text
      assert_match "up to 10 accounts", text
      assert_select "a[href='https://nalgorithm.cypherpunk.today']"
      assert_select "a[href='https://lievik.cypherpunk.today']"
      assert_match "35,000 sats", text
    end
  end
end
