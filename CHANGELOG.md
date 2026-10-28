# Changelog

Notable changes to Jutsu Studio. Versions follow [Semantic Versioning](https://semver.org); release notes on GitHub are written from [docs/release-notes-template.md](docs/release-notes-template.md).

## [Unreleased]

### Added

- Subtitles… on a video's menu and page hears its speech on-device, free and without an account, with macOS 26's own speech models: SpeechTranscriber for the languages it has, Dictation for the others. Only the sound track is read; a video without sound, or with only silence, ends at once with "No speech found", and a file the app can't open says so. A language's model is downloaded from Apple once, after you agree to it for that language in the sheet. One run at a time, in the background, with its progress on the card and Cancel on the result's page and the card's menu; the same file heard again in the same language comes from a cache. The subtitles belong to the version they were made from.
- The heard words become subtitle cues by the usual rules: at most two lines of 42 characters, 1 to 7 seconds each, split at sentence ends and pauses, never overlapping. A word the model stretched over a pause is cut back, and a lone word after a long pause joins a neighbour where both fit. In languages written without spaces, such as Chinese and Japanese, the words join without them. Edit Subtitles on the result's page opens them beside the player: edit a cue's text, merge it with the next or split it, and the cue on screen follows playback. Done saves them on the version the editor opened on, and asks first when that version's subtitles were made again meanwhile. The language picker starts on the last language used, then the system's.
- Export for Editing can write a version's subtitles as an `.srt` next to the take, and each video output of a Delivery Set has Subtitles: None, SRT + VTT next to the video, or Burn In, which draws each cue into the frames in white semibold text with a soft shadow inside the bottom safe area, sized to the frame. Subtitle files are timed as the exported video is; an output with subtitles fails for a version that has none. A take's `.srt` gets the take's name, and the version number moves on when either is taken; a delivery output's video and subtitle files are moved in together, so a failed or canceled export leaves the folder as it was.
- Parakeet Ultra, a speech model for 25 European languages, can make subtitles too: the Subtitles sheet picks Built-in or Parakeet Ultra, and Settings › Subtitles downloads the model from its pinned Hugging Face revision (about 630 MB, resumable, each file checked against its hash), shows its size, memory, languages and CC BY 4.0 license, and removes it. Settings › Storage counts it. A new revision's download removes the earlier revision's folder. The model is loaded only for a run and released after; a run is refused, and says so, when too little memory is free. It runs with FluidAudio (Apache License 2.0), with every optional package trait off so no prebuilt binary is linked.
- Settings › Subtitles picks the default speech model: Auto (macOS's SpeechTranscriber when it has the language, else Parakeet Ultra once it is downloaded, else Dictation), Built-in or Parakeet Ultra; the Subtitles sheet can pick another for a run.
- Agents can make subtitles with the new `subtitles` tool, free and idempotent by `request_id`: `make` answers with a run of kind `on_device` (operation `subtitles`) that `jobs` follows and `job_action` cancels, `get` reads the current version's cues, with the SRT or VTT text on request, and `export` writes an `.srt` or `.vtt` into the Exports folder. A run that needs the person, to agree to a model download or to download Parakeet Ultra, answers `needs_person`, and `show` with `sheet: "subtitles"` opens the Subtitles sheet. `capabilities`' `onDevice.subtitles` lists each speech model with its languages and model state, and the default engine.
- Settings › General › Run in the menu bar keeps Jutsu Studio running in the menu bar with every window closed, for when agents drive it: with no window open it leaves the Dock and the app switcher, and comes back as soon as a window opens. Open at login then starts it with no window. Both are off until you turn them on. The Dock icon's menu has Open Jutsu Studio, Queue, Library, Pause All, Resume All and Settings…. With every window closed, Jutsu Studio lets go of the thumbnails and pictures the window showed.
- The menu bar panel is redesigned for macOS 26's Liquid Glass, with standard materials on earlier versions: the connection and the agents (Allow agents, which clients are connected, Pause agents), today's agent budget with what is spent, reserved and left and your own cap, what needs you (held jobs and agents' requests for a model download, each opening where you settle it), what runs with progress and Cancel, and the last results with a frame. The menu bar icon shows how far the running work is.
- When an agent's call finds Jutsu Studio not running, the `jutsu` helper starts it in the background with no window and without taking the focus; `show` opens the window. `capabilities` says whether a window is open and whether the app runs in the menu bar (`window`).
- Kling 4.0, with an API key and on a Higgsfield account: a 3–30 s clip at 720p or 1080p from a prompt, from a start and an optional end frame, or from up to ten images and the source video as references, and Edit of a video as the prompt says, with up to ten images. A clip without a source gets the frame asked for, or the nearest of 21:9, 16:9, 9:16 and 1:1. With an API key it shows the list price; on an account a prompt alone is quoted before upload and anything with media once it is uploaded, with Higgsfield's announced 5 and 7.5 credits a second as the estimate until then, and 1.2 times that with a source video, as its API price bills the input video too. With an API key the prompt's `@Image1` and `@Video1` tags are sent as Kling 4.0 names its inputs. A Kling 4.0 result imported from the account's history comes back as an Edit or a clip from frames when its history says so. Agents get it through `create_video`, `quote` and `capabilities`.
- Genjutsu Lite takes up to ten reference images, and each of its modes offers the resolutions it renders at: Motion Transfer 480p, 720p and 1080p, Object Swap 720p and 1080p. `capabilities` with `model` lists each mode's resolutions.

### Fixed

- Genjutsu Lite's Object Swap at 480p, the default resolution and Draft's, is made at 720p: Higgsfield's Lite Object Swap doesn't render at 480p, and the request asked for it. A job stored at 480p is read as 720p, so its price, the Queue and the Library say what it is made at.
- With an API key, a submit refused because the account's Higgsfield queue is full now waits as long as Higgsfield asks (`Retry-After`) and is sent again with the same idempotency key, so it can't be charged twice; it no longer pauses the job as kept failing. A brief queue admission outage is retried like any server error instead of reading as an unavailable model.
- An API key that expired or was disabled in the Higgsfield console is reported as a refused key that needs attention in Settings, not as an empty balance; the message says the key is wrong, expired or disabled.
- Hashing a large file, as the upload cache and the transcript cache do, reads it a chunk at a time without keeping the chunks read in memory until it is done; a large video took as much memory as its size.

## [0.2.5] - 2026-10-27

### Added

- Enhance › Smooth Motion… makes new frames between a result's own on this Mac, free and without an account: 60 fps keeps the clip's length and sound, 2× and 4× Slow Motion play it longer at its own frame rate without sound. Across a hard cut a frame is repeated instead of blending the two shots. The sheet says how long it takes; the result becomes a new version of the item, linked to the version it was made from, which stays as it is. Runs go one at a time at background priority, one per item until its new version is in, show their progress on the card and the result's page, and can be canceled, leaving no file behind. Needs macOS 15.4 or later.
- Enhance › Upscale › On This Mac… makes a result up to 720p four times larger with macOS's own super resolution, free and keeping the sound; it isn't offered for larger results. A portrait frame the engine won't take is turned for it and back. An H.264 result stays H.264 up to 4096 pixels a side; anything larger, and every other codec, becomes HEVC. The sheet says how long it takes before it starts. The first upscale asks before macOS downloads its model from Apple once (about 62 MB); the card shows the download, then the frames. Needs macOS 26 or later.
- Upscale on This Mac… on an image's menu makes an image up to 1920×1080 four times larger the same way, as a new version in the source's file type (PNG when macOS can't write it). Transparency isn't kept: the result is opaque, and the sheet says so for an image that has it. The image engine has a model of its own, asked about separately.
- Agents can run Smooth Motion and Upscale on This Mac through enhance, free and without max_cost, and follow or cancel the run with jobs and job_action. capabilities says which engines this Mac has, their limits and whether the upscale model is agreed to; an upscale before that asks the agent to open the sheet with show so you can agree. library_get names the version a result was made from.
- Compare with Original on a result's or an image's menu plays or shows a version made on this Mac, or edited in another app, beside the version it was made from.

### Changed

- The agent tools' input schemas state the maximums the app already enforced: `variants`, `image_count`, `length`, `source` `start`/`end`, `library_search`'s `model` and `enhance`'s `voice`.
- An agent's image request that waits for you, held by the agent spending limits or over today's spending cap, gives its reason in the same words as a held agent video job, followed by "review to send it", in the Queue and on its tile in Create.

### Fixed

- Delete from Library moves the files of an item's earlier versions in the output folder to the Trash too, not only the current one, and the confirmation says so; files of versions that live elsewhere or that a delivery set holds are left alone. A run on this Mac on the item stops first, so its result never brings the item back.
- An export that fell back to re-encoding read and wrote its frames on Swift's shared threads, where blocked calls could stall other media work; it now runs on a thread of its own.

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

[Unreleased]: https://github.com/jutsuhq/jutsu-studio/compare/v0.2.5...HEAD
[0.2.5]: https://github.com/jutsuhq/jutsu-studio/compare/v0.2.2...v0.2.5
[0.2.2]: https://github.com/jutsuhq/jutsu-studio/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/jutsuhq/jutsu-studio/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/jutsuhq/jutsu-studio/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/jutsuhq/jutsu-studio/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jutsuhq/jutsu-studio/releases/tag/v0.1.0
