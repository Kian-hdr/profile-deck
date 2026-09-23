# Profile Deck contributor guide

Profile Deck is a GPL-3.0-only macOS 26+ Apple silicon companion for separately
installed ChatGPT/Codex clients. Read `README.md`, `PRIVACY.md` and the nearest
source files before changes. `project.yml` defines the app and test targets.

## Build and test

- Install Xcode and XcodeGen. Run `./script/test.sh` for the synthetic suite.
- Run `./script/build_and_run.sh --build` for a local build. To launch a
  development build, quit an existing Profile Deck process normally first.
- Use `--demo` or `--demo-scale` for screenshots and UI checks. Demo profiles
  must never point at real account folders.
- Keep the SwiftUI manager, menu and floating tabs coordinated through
  `AppModel`. AppKit bridges should remain narrow and preserve native clients.

## Data and release boundaries

- Never commit credentials, OAuth links, API keys, profile directories,
  account databases, browser data, diagnostics or private project records.
- Tests that write files must use disposable fixture directories. Never use a
  developer's real Codex home or installed provider bundle as a mutation target.
- Profile Deck does not bundle the official client. It must not copy account
  logins, merge profile histories, or infer task status from process presence.
- Versioned public releases use Developer ID signing and Apple notarization.
  GitHub source, direct-download DMG and Homebrew Cask are separate artifacts;
  verify each before describing it as delivered. The Mac App Store requires a
  separate build and review path.
- The first public 0.2.1 build has no live in-app update feed. Do not turn on
  automatic checks until a signed feed and real update path have been tested.
