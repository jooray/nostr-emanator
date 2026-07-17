// Bump CACHE_VERSION on every meaningful change: it renames the cache AND
// changes this file's bytes, so the browser installs a fresh worker, drops old
// caches on activate, and (with skipWaiting + clients.claim + the page-side
// controllerchange reload) auto-updates without a manual hard refresh.
const CACHE_VERSION = "v2"
const CACHE_NAME = `emanator-${CACHE_VERSION}`

// Precache only tiny, stable app-shell icons.
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(["/icon.png", "/icon.svg"]))
  )
  self.skipWaiting()
})

// Drop caches from older versions on activate.
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)))
    )
  )
  self.clients.claim()
})

// IMPORTANT: only ever intercept same-origin GETs for *hashed static assets*.
// Navigations, API calls, redirects (login), Turbo requests, and WebSockets are
// left entirely to the browser. A service worker that answers navigations is how
// you get "hard refresh works but every click 404s": an edge-case/failed fetch
// falls back to caches.match() -> undefined -> a broken/404 navigation. The old
// v1 network-first-for-everything handler did exactly this.
self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return

  const url = new URL(event.request.url)
  if (url.origin !== self.location.origin) return

  const isStaticAsset =
    url.pathname.startsWith("/assets/") ||
    /\.(png|svg|ico|woff2?)$/.test(url.pathname)
  if (!isStaticAsset) return // let the network handle everything else

  // Cache-first for fingerprinted assets (safe: their URL changes on change).
  event.respondWith(
    caches.match(event.request).then(
      (cached) =>
        cached ||
        fetch(event.request).then((response) => {
          if (response.ok && response.type === "basic") {
            const clone = response.clone()
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone))
          }
          return response
        })
    )
  )
})
