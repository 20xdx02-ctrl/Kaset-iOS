<p align="center">
  <img src="Sources/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="140" alt="Kaset icon">
</p>

<h1 align="center">Kaset for iOS</h1>

<p align="center">
  A native SwiftUI YouTube Music client for iPhone and iPad, built to play music with the screen
  locked — without running the YouTube web app.
</p>

---

Kaset for iOS is an unofficial, open-source YouTube Music client. The app targets **iOS 15+** and
plays music with a native `AVPlayer`: the YouTube Music web app is no longer used for playback. It
gives you background playback, lock-screen and AirPods controls, queue management and an
Apple Music-like interface with your own YouTube Music account.

`WKWebView` is used only where a real web session is still needed: the sign-in flow and account
switcher. It is never part of the playback path — there are no injected scripts and no hidden
music player page running in the background.

> **Disclaimer** — Kaset is an independent, unofficial project and is not affiliated with or
> endorsed by YouTube or Google. You are responsible for complying with YouTube's Terms of Service
> and local laws. Ad skipping is opt-in and may go against YouTube's terms.

## Features

- Native `AVPlayer` playback, including background audio and remote controls.
- Native shell with a bottom tab bar: **Home · Discover · Collections · Search**; the mini player
  sits above the tabs and expands into the full Now Playing screen.
- Now Playing metadata, artwork and playback controls on the lock screen and in Control Center,
  with the queue showing track names, artists and cover art.
- Settings for streaming quality (`Auto`, `Low`, `Normal`, `High`), extra buffering, adaptive
  quality and "skip ads". The quality preference selects a cheaper progressive stream on slow
  links; "skip ads" only affects app behaviour — it does not remove ads from YouTube itself.
- Covers are requested at `mqdefault` (320×180) on cards and shelves, decoded down to 480 px and
  cached in memory and on disk. Prefetching keeps scrolling smooth on older devices.
- Session restore: you stay signed in across launches, and a new bundle can be installed over the
  existing app without losing its data.
- English and French localisation.

## How it works

`NativeStreamResolver` performs an anonymous Innertube (`ANDROID` client) player request and
returns a single playable stream URL plus the metadata needed by `AVPlayer` and
`MPNowPlayingInfoCenter`. `KasetPlayer` owns the player, queue, lock-screen info and remote command
handlers (`MPRemoteCommandCenter` with an active `.playback` audio session). UI state is throttled:
position ticks update the system now-playing card but do not re-render the whole SwiftUI view tree.

The YouTube Music web view survives only in `Sources/Auth/LoginView.swift` and
`Sources/Auth/AccountSwitcher.swift`, where cookies from a real sign-in are required.

## Requirements

- iOS 15 or later (iPhone and iPad).
- A YouTube Music account for signing in.

The repository still carries the macOS target for reference, but development is iOS-first: new
code must compile for iOS 15, and macOS compatibility is not a constraint for new features.

## Build

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen), and the GitHub
Actions workflow builds an unsigned iOS IPA on every push and pull request to `main`:

```bash
brew install xcodegen
xcodegen generate
open KasetiOS.xcodeproj
```

The built IPA is uploaded as the `KasetiOS-unsigned` artifact. No manual `workflow_dispatch` run
is needed after a push — the automatic build already produces the artifact.

## Install / update on a jailbroken iPad

Copy the app bundle from the IPA over the existing bundle, leaving the application's data
container untouched (settings, login session and logs stay in place):

1. Unzip the artifact and extract `Payload/KasetiOS.app`.
2. Stop the running app, replace only the contents of the existing
   `/var/containers/Bundle/Application/<UUID>/KasetiOS.app` directory, then re-sign the bundle
   (`ldid -S` on the app directory).
3. Relaunch with `uiopen dev.emoona.kaset`.

Do **not** delete the `/var/mobile/Containers/Data/Application/<UUID>` directory: that is where the
app keeps its data. Copying only the bundle updates the app without logging you out.

## Development notes

- `swiftc -parse` over `Sources/**/*.swift` is a quick syntax check; CI performs the real build.
- `docs/spike-findings.md` records the earlier WebView-player experiment and why it was replaced
  by native playback.
- Keep network calls anonymous and avoid logging cookies, tokens or full API responses.
- New playback code should not introduce another `WKWebView`; the web view is limited to auth.

## Contributing

Issues and pull requests are welcome. Before changing an endpoint parser, verify it against the
real service; keep playback native; never commit cookies, tokens or personal responses.

## Acknowledgements

- [**Kaset for macOS**](https://github.com/sozercan/kaset) by Sertaç Özercan — the InnerTube
  client, parsers, models and app icon come from this project (MIT).
- [**Opaline**](https://github.com/verback2308/Opaline) — parts of the native stream resolver and
  player are adapted from its GPL-3.0 code; see the headers in
  `Sources/NativePlayback/NativeStreamResolver.swift` and `Sources/Playback/KasetPlayer.swift`.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## License

[MIT](LICENSE). Portions adapted from Kaset for macOS are covered by its MIT license, reproduced
in the same file. The Opaline-derived files remain under GPL-3.0 as noted in their headers.
