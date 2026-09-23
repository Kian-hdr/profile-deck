# Install Profile Deck on my Mac

Install or upgrade the current stable Profile Deck from
`https://github.com/Kian-hdr/profile-deck`. I authorize the download and local
installation. Complete routine steps autonomously and preserve my existing
ChatGPT/Codex applications, profile folders, credentials and histories.

1. Confirm this is an Apple silicon Mac running macOS 26 or later. Check the
   repository's latest published stable release, its requirements and its
   matching `Kian-hdr/tap/profile-deck` Homebrew cask. The official
   ChatGPT/Codex app is a separate prerequisite; do not download or alter it
   as part of this installation.
2. If Profile Deck is already managed by Homebrew, use the verified cask to
   upgrade it. Otherwise, use Homebrew when available:

   ```sh
   brew tap Kian-hdr/tap
   brew install --cask Kian-hdr/tap/profile-deck
   ```

   Inspect the cask's versioned GitHub DMG URL and SHA-256 before installing.
   Keep Homebrew quarantine and Gatekeeper enabled. If Homebrew requires a
   one-time trust action for this cask, explain the exact scope and use the
   supported Homebrew flow. Do not trust unrelated casks or install unrelated
   updates.
3. If Homebrew is unavailable, download the versioned `.dmg` and `SHA256SUMS`
   from the same official GitHub release. Verify the downloaded SHA-256,
   `hdiutil verify`, the DMG's Developer ID signature and Gatekeeper open
   assessment. Mount it read-only and verify the enclosed `Profile Deck.app`
   with strict `codesign`, a stapled ticket and Gatekeeper. Quit an older
   Profile Deck normally, keep a recoverable copy, then copy the verified app
   to `/Applications`. Eject the DMG after installation. Stop if any check
   fails; do not remove quarantine, re-sign the download or bypass macOS trust.
4. Open the installed app and check its version, bundle identifier
   `space.exlumina.profiledeck`, signature, Gatekeeper acceptance and visible
   manager window. Confirm there is only one active Profile Deck process.
   Profile adoption, account sign-in, MCP authorization and Accessibility
   permission remain user-controlled choices. Explain them in the app; do not
   copy, display or request API keys or OAuth tokens in chat or logs.
5. Report the actual release tag, download/cask URL, hash, installed version,
   launch result and any checks that could not be performed. A running app
   does not prove profile switching, provider login or cross-account tool use.

The first public release does not perform in-app update checks. For a later
version, repeat the verified GitHub or Homebrew upgrade path.
