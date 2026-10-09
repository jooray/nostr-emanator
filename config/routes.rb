Rails.application.routes.draw do
  # Authentication
  get "auth/nostr", to: "sessions#new", as: :nostr_login
  post "auth/nostr/poll", to: "sessions#poll", as: :auth_nostr_poll
  post "auth/nostr/callback", to: "sessions#callback", as: :auth_nostr_callback
  # bunker:// — the signer-initiated flow, where the user pastes a URI
  # naming their signer instead of the signer scanning ours.
  post "auth/nostr/bunker", to: "sessions#bunker", as: :auth_nostr_bunker
  post "auth/nostr/refresh_profile", to: "sessions#refresh_profile", as: :refresh_profile
  delete "logout", to: "sessions#destroy", as: :logout

  # Public landing page
  root "home#index"

  # Dashboard (the app home for signed-in users)
  get "dashboard", to: "dashboard#index", as: :dashboard

  # New post account picker — must precede the shallow `/posts/:id` route
  get "posts/new", to: "posts#select_account", as: :new_post

  # Accounts
  post "accounts/pair_poll", to: "accounts#pair_poll", as: :account_pair_poll
  resources :accounts do
    member do
      post :refresh_profile
      post :refresh_relays
      get :re_pair
      post :re_pair_poll
      get :settings
      get :recent_events
      get :recent_interactions
      # Nostr profile (kind 0) editing. Publishing blocks on signer approval, so
      # `update_profile` enqueues and `profile_status` is what the page polls.
      get :profile
      post :profile, action: :update_profile
      get :profile_status
    end
    resources :posts, shallow: true
    resources :nostr_actions, only: [:create], shallow: true
    resources :blossom_uploads, only: [:create]
  end

  # Upload progress polling (C6): created nested under an account, polled by id.
  resources :blossom_uploads, only: [:show]

  resources :nostr_actions, only: [:show] do
    member do
      post :retry
    end
  end

  # Interactions (global view across all accounts)
  resources :interactions, only: [:index]

  # Messages — one private-DM inbox across every paired account.
  get "messages", to: "conversations#index", as: :messages
  post "messages/mark_all_read", to: "conversations#mark_all_read", as: :mark_all_read_messages
  resources :conversations, only: [:show], path: "messages" do
    member do
      post :accept
      post :block
      post :mark_read
      # Just the composer, so it can re-resolve its delivery mode in place while
      # a peer's DM relay list is still being looked up.
      get :composer
    end
    resources :messages, only: [:create]
  end
  post "messages/:id/retry", to: "messages#retry", as: :retry_message
  # Resend a failed private message as an acknowledged legacy one, for a
  # recipient who cannot receive NIP-17 at all.
  post "messages/:id/downgrade", to: "messages#downgrade", as: :downgrade_message

  # Posts (all posts view)
  # Bulk discard for posts that never went out. Without it the only way to clear
  # a backlog of dead scheduled posts was to open each one and retry it.
  #
  # NOT under /posts/… : the shallow `resources :posts` above already owns
  # DELETE /posts/:id, so /posts/failed was recognised as posts#destroy with
  # id="failed", raised RecordNotFound, and Turbo swallowed the 404 — the button
  # appeared to do nothing at all.
  delete "failed_posts", to: "posts#discard_failed", as: :discard_failed_posts
  resources :posts, only: [:index] do
    member do
      get :schedule
      post :sign
      post :retry_sign
      post :retry_publish
      post :rebroadcast
      post :cancel
      post :reschedule
    end
    resources :reposts, only: [:destroy] do
      member do
        post :retry_sign
        post :rebroadcast
        post :publish_now
      end
    end
  end

  # Calendar
  get "calendar", to: "calendar#index", as: :calendar

  # AI assist
  # H5: generate_stream/refine_stream used to be GET, so a SameSite=Lax
  # top-level navigation (a crafted link) could trigger a paid AI call from a
  # logged-in user's browser with no confirmation. POST only — the client
  # streams the SSE response via fetch()/ReadableStream instead of EventSource
  # (which cannot POST).
  post "ai/generate", to: "ai_assist#generate"
  post "ai/generate_stream", to: "ai_assist#generate_stream"
  post "ai/refine", to: "ai_assist#refine"
  post "ai/refine_stream", to: "ai_assist#refine_stream"

  # Paid AI assist on the hosted instance (404 when billing is not configured)
  get "billing", to: "billing#show", as: :billing
  post "billing/charges", to: "billing#create_charge", as: :billing_charges

  # User settings
  get "user/edit", to: "users#edit", as: :edit_user
  patch "user", to: "users#update", as: :user
  post "locale", to: "locales#update", as: :locale

  # API tokens (for MCP access)
  resources :api_tokens, only: [:create, :destroy]

  # MCP (Model Context Protocol) endpoint — auth via Authorization: Bearer <api token>
  post "/mcp", to: "mcp/server#handle"

  # Where BTCPay sends a payer who paid from the Android app. Public: the phone's
  # browser holds no Emanator session; the page only hands them back to the app.
  get "billing/return", to: "billing_returns#show", as: :billing_return

  # The Android app's download page (also what Obtainium and update prompts link to).
  get "android", to: "android_app#show", as: :android_app

  # Native app API (Android). Device-token auth; see Api::V1::BaseController.
  namespace :api do
    namespace :v1, defaults: { format: :json } do
      get "meta", to: "meta#show"

      post "auth/nostrconnect", to: "auth#nostrconnect"
      post "auth/bunker", to: "auth#bunker"
      post "auth/poll", to: "auth#poll"
      delete "session", to: "auth#destroy"

      get "me", to: "me#show"
      patch "me", to: "me#update"
      get "me/summary", to: "me#summary"
      post "me/refresh_profile", to: "me#refresh_profile"
      resources :devices, only: %i[index destroy]
      resources :mcp_tokens, only: %i[index create destroy]

      get "dashboard", to: "dashboard#show"
      get "calendar", to: "calendar#index"
      get "interactions", to: "interactions#index"

      resources :accounts, only: %i[index show update destroy] do
        member do
          post :refresh_profile
          post :refresh_relays
          get :recent_events
          get :recent_interactions
          get :profile
          post :profile, action: :update_profile
          get :profile_status
        end
        resources :uploads, only: :create
        resources :nostr_actions, only: :create
      end
      resources :pairings, only: %i[create show]
      resources :uploads, only: :show
      resources :nostr_actions, only: :show do
        post :retry, on: :member
      end

      delete "failed_posts", to: "posts#discard_failed"
      resources :posts, only: %i[index show create update destroy] do
        member do
          get :schedule_options
          post :schedule
          post :retry_sign
          post :retry_publish
          post :rebroadcast
          post :cancel
          post :reschedule
        end
        resources :reposts, only: :destroy do
          member do
            post :retry_sign
            post :rebroadcast
            post :publish_now
          end
        end
      end

      post "messages/mark_all_read", to: "conversations#mark_all_read"
      resources :conversations, only: %i[index show] do
        member do
          post :accept
          post :block
          post :mark_read
        end
        resources :messages, only: :create
      end
      resources :messages, only: :show do
        member do
          post :retry
          post :downgrade
        end
      end

      post "ai/generate", to: "ai_assist#generate"
      post "ai/generate_stream", to: "ai_assist#generate_stream"
      post "ai/refine", to: "ai_assist#refine"
      post "ai/refine_stream", to: "ai_assist#refine_stream"

      get "billing", to: "billing#show"
      post "billing/charges", to: "billing#create_charge"
    end
  end

  # PWA
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
