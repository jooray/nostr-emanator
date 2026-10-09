# Emanator for Android

The native Android client for [Emanator](../README.md). It talks to an Emanator
server's JSON API (`/api/v1`) — the same models, services and jobs that serve the
web app — so everything you do in one shows up in the other, and the two always
agree about what an action does.

## What it adds on a phone

- **Signer on the same phone.** Log in and pair accounts by handing the
  `nostrconnect://` link straight to Amber (or another NIP-46 signer). A QR code
  and `bunker://` links are there for a signer on another device.
- **Native media.** Photo Picker, file picker, camera, and *Share → Emanator*
  from any app.
- **Photos shrunk on the phone.** Blossom servers store exactly the bytes they
  receive, so the app resizes and re-encodes photos *before* uploading, which also
  removes EXIF/GPS metadata. The rules and settings are shared with the web
  composer (Settings → Photo uploads).
- **Local first.** Every screen opens from the copy kept on the phone, then
  refreshes.
- **Everything else the web has**: dashboard, posts, scheduling with reposts,
  calendar, AI writing (streamed), private messages, interactions, accounts and
  profiles, devices, MCP tokens, and the paid AI writing plan.

Languages: English, Slovenčina, Čeština, Español.

## Building

Requires the Android SDK (compileSdk 37). With Android Studio's bundled JDK:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew assembleDebug testDebugUnitTest
```

The debug build uses the `today.cypherpunk.emanator.debug` application id, so it
installs beside a release build. The default server is
`https://emanator.cypherpunk.today`; self-hosters change it on the login screen.

## Versioning

The app sends its `versionCode` with every request. A server configured with a
higher `android.min_version_code` (in `config/emanator.yml`) answers `426` and the
app asks to be updated, so an old build never half-works against a newer API.
