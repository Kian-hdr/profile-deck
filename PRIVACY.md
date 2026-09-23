# Privacy

Profile Deck stores manager metadata locally. It has no analytics SDK, hosted backend or automatic diagnostic upload. It does not pool accounts or copy tokens between profiles.

Native profiles own their credentials. Profile Deck may pass an explicitly entered API key to the selected official provider login helper through standard input; the manager does not persist that key. Provider helpers may contact their service during user-requested authentication or configuration operations.

The optional account browser opens Google Chrome with a separate data directory for each Profile Deck profile under `~/Library/Application Support/Profile Deck/MCP Browsers`. Chrome stores that browser session's cookies and sign-in state there; Profile Deck does not read, copy, export or log them. **Open copied sign-in link** reads the current clipboard only when selected, accepts an HTTPS or loopback HTTP authorization URL, and passes it to Chrome without saving it in the manager database or diagnostics. Authorization links can contain short-lived login state and should not be shared.

Before an in-app MCP OAuth login, Profile Deck can configure the selected Codex home to use `mcp_oauth_credentials_store = "file"`. Codex then writes that account's OAuth tokens to `.credentials.json` with owner-only file permissions. The tokens are unencrypted at rest and can be read by software running as the same macOS user. Profile Deck does not read the token file. Preparing the setting requires the native account to be closed; existing shared keyring entries remain untouched and previously connected MCPs may require sign-in again in the selected account.

Shared instructions, skills and approved local memory documents remain at their canonical locations. They can contain private information. They are not included in the default portable export or screenshots.

Routine diagnostic events contain generic operation information, capped to seven days and 2,000 events. No prompts, conversation bodies, credentials, raw helper responses or runtime endpoints are logged. Diagnostic export strips profile names, account identity and filesystem paths.

Notifications are opt-in and can include profile labels. Sounds are off by default. Disable or mute notifications if those labels are sensitive on a shared screen.

The clipboard handoff action copies the exact reviewed work brief. When a user supplies an approved `https://chatgpt.com/share/...` link, the link is included as a reference snapshot; Profile Deck does not fetch or read it. Private Codex and ChatGPT thread links are omitted from copied briefs and cannot be used to transfer conversation access between profiles. Other clipboard-accessing software may read copied content. No handoff is silently submitted.

## Window access

Optional macOS Accessibility access is used only for an explicit profile focus action to inspect the selected process's focused/main window, its geometry/full-screen/minimized state, and to restore/raise that window. It does not read conversation text or copy window titles. Public window metadata confirms onscreen arrival. Window references and geometry are not persisted. Permission is requested only from the Enable window access button; users grant or revoke it in System Settings.

## Account usage and optional billing cache

A temporary official-client account reader uses the selected profile’s existing login in place. Profile Deck requests account details without forcing token refresh and reads subscription rate limits only for a reported ChatGPT login. It never submits a task to obtain usage. The provider may perform its own normal authentication maintenance. Responses and credentials are not logged. Account identity and quota timestamps remain in the manager database.

An explicitly linked Prompt Balance source is read from its local SQLite cache in read-only mode. Only source labels, cost totals, dates and health/revision fields are selected. No billing keys, credential references or manual credit estimates are read. The linked totals cover the source organization’s API activity across projects, not just this profile. Credentials, usage observations and source bindings are excluded from portable exports.

## Software updates

The first public 0.2.1 build has no active in-app update feed. Its automatic
checks and downloads are disabled; install a later verified release from GitHub
or upgrade through Homebrew. The bundled Sparkle framework is reserved for a
future separately verified signed update channel. It does not send profile
contents, conversations, API keys or shared documents. Sparkle system profiling
and JavaScript are disabled. Existing update preferences remain stored but do
not start network checks in this release.
