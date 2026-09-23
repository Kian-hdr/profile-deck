# Direct release process

Profile Deck 0.2.1 is a macOS 26+ Apple silicon direct-download release. Build
from a reviewed clean public source commit. The Mac App Store needs a separate
sandboxed build and is not produced by this process. In-app updates are disabled
in this first public release.

1. Run `./script/test.sh`, the public-source secret scan and the dependency
   inventory check. Confirm the version, build, bundle ID, original icon and
   licenses before tagging. Use disposable test paths, never real account homes.
2. From the clean reviewed commit, run `script/release_direct.sh` with an
   installed Developer ID Application identity, an existing Keychain notary
   profile and a fresh output directory outside the repository. The script
   archives a Release app, signs it with Hardened Runtime and timestamp,
   submits the app ZIP, staples the accepted app, then creates, signs,
   notarizes and staples the exact DMG. It records source, results and final
   SHA-256 checksums. The script never publishes or modifies a live app.
3. Independently inspect signatures, entitlements, version, architecture and
   bundled licenses. Mount the final DMG read-only and test a real install and
   launch before publication.
4. Publish the immutable source tag and GitHub Release with the DMG, checksums
   and corresponding source. Download the public asset without authentication
   and compare its bytes. Add a Homebrew Cask using that hosted DMG hash, then
   run current style, strict online audit and isolated install/launch checks.

Never include account folders, credentials, OAuth links, runtime databases,
private diagnostics or the separately installed official client in source or
release artifacts. An `Accepted` notary result, local save, GitHub upload and
public download are distinct states. Record exact evidence for each before
reporting success.
