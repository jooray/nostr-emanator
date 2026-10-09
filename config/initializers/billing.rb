# frozen_string_literal: true

# Build the billing gate at boot so a half-configured install (URL without a
# token, plain http to a remote host) fails on start, not on the first AI click.
Rails.application.config.after_initialize do
  Billing.gate unless Rails.env.test?
end
