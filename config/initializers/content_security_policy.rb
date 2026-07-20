# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header
#
# M2: the app renders a large amount of untrusted Nostr content (profiles,
# post text, mentions) — currently well-escaped, but CSP is the backstop if
# an escaping bug is ever introduced. There are two inline <script> blocks
# (layouts/application.html.erb's PWA-refresh snippet, home/index.html.erb's
# landing-page theme toggle), both given an explicit `nonce: true`. There's
# one inline `style="width: ...%"` attribute (posts/_signing_progress —
# a server-computed percentage, not user input), so `style-src` allows
# `unsafe-inline` rather than hashing/noncing every progress bar; nothing
# else in the app relies on inline styles or scripts. Avatars/profile
# pictures come from arbitrary Nostr relay-supplied URLs, hence
# `img-src https:`.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.img_src      :self, :https, :data
    policy.font_src     :self
    policy.object_src   :none
    policy.script_src   :self
    policy.style_src    :self, :unsafe_inline
    policy.connect_src  :self
    policy.base_uri     :self
    policy.form_action  :self
  end

  # Generate session nonces for permitted inline scripts. Not just
  # `request.session.id.to_s` (the Rails default template's suggestion):
  # pages that never touch the session (e.g. the logged-out landing page,
  # which has no csrf_meta_tags/forms) get a lazy, unloaded session whose id
  # is nil — that would silently emit an empty `nonce=""` that never matches
  # the CSP header, blocking home/index.html.erb's inline scripts. Fall back
  # to a random per-request nonce in that case (memoized per request same as
  # the session-id path, so both the header and every script tag agree).
  config.content_security_policy_nonce_generator = ->(request) do
    session_id = request.session.id
    session_id.present? ? session_id.to_s : SecureRandom.base64(16)
  end
  config.content_security_policy_nonce_directives = %w[script-src]

  # Enforced, not report-only: no known inline script/style outside the two
  # nonced blocks and the one server-controlled inline style above.
  # config.content_security_policy_report_only = true
end
