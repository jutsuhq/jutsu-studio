# Changelog

Notable changes to Jutsu Studio. Versions follow [Semantic Versioning](https://semver.org); release notes on GitHub are written from [docs/release-notes-template.md](docs/release-notes-template.md).

## [Unreleased]

### Added

- Genjutsu Lite, a cheaper Genjutsu for motion transfer and object swap (up to 15 s), picked next to Genjutsu in Create on a Higgsfield account. Templates, drafts, finals and agents can use it; with an API key it isn't offered yet, and what was saved with it runs on Genjutsu.

## [0.1.0] - 2026-10-14

The first public release.

### Added

- Motion transfer, object swap and restyle with the Higgsfield Genjutsu models in one window. On a Higgsfield account, motion transfer can also run on Seedance 2.5 or Kling 3.0 Motion Control, and Seedance makes a clip from a prompt and images alone.
- Two ways to connect: a Higgsfield account through Higgsfield's MCP server (plan credits) or your own API key (pay as you go). Credentials are kept in the macOS Keychain; no key ships with the app.
- Input prep on the Mac: transcoding with AVFoundation, 4–30 s range trimming, HEIC to JPEG, fitting under the 200 MiB upload limit and an upscale offer for small object-swap frames.
- A price on every button before you pay, an optional daily spend cap, a low-credits warning and a spending breakdown with CSV export.
- 480p Quick Preview drafts before a 720p or 1080p final.
- A queue that runs in the background within the account's concurrency limit, resumes after a restart or a dropped connection, and never submits a job twice.
- A local library in `~/Movies/Jutsu Studio` with each result's inputs, prompt and cost, a before/after player, Higgsfield history beside local results, and "render final" / "edit & re-run".
- Export to ProRes 422 or H.264 for Premiere Pro, DaVinci Resolve and Final Cut Pro, with an optional JSON sidecar.
- The restyle preset gallery with search, favorites and recents.
- Menu bar status, Dock badge, notifications and open at login.

[Unreleased]: https://github.com/jutsuhq/jutsu-studio/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jutsuhq/jutsu-studio/releases/tag/v0.1.0
