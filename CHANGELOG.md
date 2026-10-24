# Changelog

Notable changes to Jutsu Studio. Versions follow [Semantic Versioning](https://semver.org); release notes on GitHub are written from [docs/release-notes-template.md](docs/release-notes-template.md).

## [Unreleased]

## [0.2.2] - 2026-10-24

### Added

- `create_video` and `create_image` take an optional `title`, which names the job in the Queue, the Library, search and export file names instead of the source's file name (or, for images, the prompt).
- `quote` gives Genjutsu Lite an estimate from its rate per second (2 credits a second at 720p) instead of an unknown price, with a `priceNote` saying the exact price is quoted before the job is sent and an estimate never runs on its own above max_cost or the budgets.
- `create_video` takes `wait_seconds` (0–50) and answers once the job's price is known or it is held, so an agent can tell at once whether it waits for the person; `timedOut` says the wait ran out.
- An agent can lift the hold on its own video job held over `max_cost`: sending the same `request_id` and parameters with a higher `max_cost` runs the job when its price fits the new `max_cost`, what is left of today's agent budget and the person's daily cap, without uploading the files again. Otherwise it stays held, and the answer says why.
- `over_cap` gives the person's daily cap, what it counts today and what the job was counted at, and `capabilities` lists the cap with the agent budget (`dailyCap`, `capTakenToday`). An upload refused for room says how much is free and how much the file needs.
- A finished video in `jobs` and `create_video` carries `next` pointing to `frames`, with `compare_source: true` when it has a source, and `capabilities` says when the running `jutsu` helper is older than the app (`helperVersion`, `helperNote`) and needs a reconnect (`/mcp` in Claude Code). Helpers from 0.2.1 and before can't tell.

### Fixed

- `jobs` with `wait_seconds` answered `still_working` instead of `timedOut` while the app was in the background: the wait counted its checks, which ran long under App Nap, and missed the answer deadline. Waits now end by the clock.
- Seedance 2.5 on an account keeps a source clip's orientation: a portrait source made a landscape video, because no aspect ratio was sent with it. The source's nearest ratio is sent now, and `quote` gives the result's frame (`aspectRatio`, `source` when it follows the source).

## [0.2.1] - 2026-10-21

### Added

- Agents can give `create_image` several input images (`inputs`), up to the model's limit, or 14 where Higgsfield's catalog states none; `input` still takes one.
- Agents can read Library items in full with `library_get`: the whole prompt, the inputs in the order sent and the settings, results only on Higgsfield included.
- Agents can take still frames of a result or a file with `frames`, and compare it with another clip or its own source on a contact sheet, written into the Exports folder. Free; a history result's source is read from its Higgsfield link.
- Agents can list your Higgsfield history in `library_search` and download results into the Library with `library_download`. Free; it never spends credits.
- Agents can use your account's characters and other elements by name in `create_video` and `create_image`, and list them with `elements`. The answer tags every image sent as @Image1, @Image2 and so on.
- `capabilities` and `quote` say how many variants a job can make and why only one, and `quote` gives how many reference images the model takes.

### Changed

- Agents' reference images follow the model's own limit instead of a fixed 16.

## [0.2.0] - 2026-10-21

### Added

- An MCP server for AI agents (Claude Code, Codex, Cursor, Claude Desktop), bundled in the app at `Contents/Helpers/jutsu`. Agents can quote, queue and follow videos and images, search and mark the Library, build and export Delivery Sets, and open the app's screens. Agents are off until allowed in Settings › Agents, and their spending is held to a daily agent budget the person sets, with every job above it waiting in the Queue for the person.
- Genjutsu Lite, a cheaper Genjutsu for motion transfer and object swap (up to 15 s), picked next to Genjutsu in Create on a Higgsfield account. Templates, drafts, finals and agents can use it; with an API key it isn't offered yet, and what was saved with it runs on Genjutsu.

### Changed

- The Keep or Reject button pressed again takes the verdict back, image frames are named by their usual aspect ratio (4:3, not 73:55), the current card's ring no longer bends around its title, and every control has a short tooltip.

## [0.1.1] - 2026-10-16

### Changed

- Account sign-in identifies Jutsu Studio by its published client metadata, so Higgsfield's consent page shows "Jutsu Studio"; the page after approving access has an Open Jutsu Studio button, and signing out goes straight to the sign-in screen.

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

[Unreleased]: https://github.com/jutsuhq/jutsu-studio/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/jutsuhq/jutsu-studio/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/jutsuhq/jutsu-studio/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/jutsuhq/jutsu-studio/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/jutsuhq/jutsu-studio/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jutsuhq/jutsu-studio/releases/tag/v0.1.0
