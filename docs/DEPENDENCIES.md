# Component and asset inventory

| Component | Shipped form | License evidence and treatment |
|---|---|---|
| Profile Deck source, documentation and original icon artwork | Source and compiled application | GPL-3.0-only; [LICENSE](../LICENSE), editable [Icon Composer source](../ProfileDeck/AppIcon.icon) and [art generator](../script/generate_icon_composer.swift). Corresponding source is linked from each release. |
| Sparkle 2.9.6 | Bundled framework in the direct-download app | MIT with included notices in [Sparkle.txt](../THIRD_PARTY_LICENSES/Sparkle.txt). The 0.2.3 release does not configure a live update feed. |
| Apple SwiftUI, AppKit, Foundation, Carbon and SQLite | Dynamic macOS system dependencies | Supplied by macOS, not copied into the release. SF Symbols are referenced through Apple APIs; symbol artwork is not redistributed separately. |
| Xcode, Swift SDK and XcodeGen | Build tools | Installed separately. `project.yml` is supplied; no build-tool binary is bundled. |
| Official ChatGPT/Codex client and its helper | Separate user installation | Not bundled, modified or relicensed. |
| User accounts, credentials, skills, plugins and shared documents | None | Never copied into the source repository, DMG or portable export. |

No third-party font, model, dataset, audio or provider binary is bundled. The
source license does not grant rights to provider names or trademarks. The
application icon is original Profile Deck artwork, with editable source included.
