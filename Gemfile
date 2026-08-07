source "https://rubygems.org"

gem "rails", "~> 8.1.3"
gem "propshaft"
gem "sqlite3", ">= 2.1"
gem "puma", "~> 7.2"
gem "jsbundling-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "cssbundling-rails"

gem "tzinfo-data", platforms: %i[ windows jruby ]

gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

gem "bootsnap", require: false

group :production do
  gem "mysql2"
end
gem "kamal", require: false
gem "thruster", require: false
gem "image_processing", "~> 1.2"

# ViewComponent for reusable UI components
gem "view_component"

# Nostr protocol support
gem "nostr", "~> 0.6"

# WebSocket client for Nostr relay communication
gem "faye-websocket"

# Bech32 encoding for Nostr addresses (npub, nsec, etc.)
gem "bech32"

# ECDSA for Nostr cryptography
gem "ecdsa"

# HTTP client for web fetching
gem "httpx"

# Environment variables management
gem "dotenv-rails", groups: [:development, :test]

# Pagination
gem "kaminari"

# QR Code generation
gem "rqrcode"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
end
