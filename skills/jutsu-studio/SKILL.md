---
name: jutsu-studio
description: Make, find and deliver Higgsfield videos and images with the Jutsu Studio app on this Mac, through its jutsu MCP server. Use when asked to generate a video or image with Jutsu Studio, use the account's characters by name, follow or cancel its jobs, search, read, download, keep, reject or star Library results, check results with still frames, upscale, reframe, dub or change the voice of a result, or export results for editing or delivery.
---

# Jutsu Studio

Jutsu Studio is a native macOS app that runs Higgsfield video and image models from the person's own API key or
Higgsfield account. You drive the running app through the `jutsu` MCP server bundled with it:

```bash
claude mcp add jutsu -- "/Applications/Jutsu Studio.app/Contents/Helpers/jutsu" mcp
```

Every tool answers with JSON. A failure is a tool error with `code`, `message`, `retryable` and `next`: do what `next`
says rather than guessing.

## Before you start

- **Allow agents.** If a tool returns `agents_off`, ask the person to turn on Settings › Agents › Allow agents in
  Jutsu Studio, then try again.
- **The budget.** Agents spend from a daily agent budget, in dollars with an API key and in credits with an account.
  It is 0 until the person sets one in Settings › Agents; the person's own daily cap applies on top of it.
- **What counts.** Every request you send counts against the budget from the moment it goes out. Higgsfield doesn't
  bill a generation that failed, was refused by moderation or was cancelled, so those give their price back once
  they end; one whose outcome isn't known keeps counting.
- **Unlimited generations.** A video the plan's unlimited generations would pay for (`quote` says `paysUnlimited`)
  costs the budget nothing, but runs on its own only while the person lets agents use them
  (`capabilities` › `budget.unlimitedAllowed`); otherwise it is held for the person (`hold: unlimited_not_allowed`).
  If one is charged anyway, `unlimitedAllowed` turns false for the rest of the day and such videos keep every limit.

## How to work

1. **Capabilities first.** Call `capabilities`. It shows the connection, today's budget (`remaining`) and the tool
   groups. `window` says whether the app has a window open (`open`) and whether it runs in the menu bar
   (`menuBarMode`): when the app isn't running, the first call starts it in the background with no window, and only
   `show` opens one. Ask for `models`, `image_models`, `styles` or `voices` when you need them; they come from what
   the app last read, never a network call.
2. **Quote before you create.** `quote` a video with the same fields you mean to send, and tell the person the price.
   It also says `maxVariants` (and `variantsUnavailable`, why only one) and `minImages`/`maxImages`, the reference
   images the model takes in that mode; the same limits are in `capabilities` with `model`. There is no fixed image
   limit: go by the model's.
3. **Create with a `max_cost`.** `create_video` or `create_image` with a new `request_id` of your own and a `max_cost`
   (`{amount, unit}`, `usd` or `credits`, matching the connection) no lower than the quote. Use a cheap draft mode when
   it fits the task (`draft: true` on models that have one, a lower resolution, fewer variants), and make the full
   version once the person likes the draft. `create_image` takes several `inputs` to edit, up to the model's
   `maxInputs`; with `maxInputsNote` that is only a bound, and Higgsfield's quote refuses (for free) what the model
   doesn't take.
   - **Clips without a source.** A model with `makesClipsWithoutSource` in `capabilities` with `model` (Seedance
     2.5, Kling 4.0) makes a clip from the prompt and `images` alone: leave out `source` and set `length` and
     `aspect_ratio`. With `needsPrompt` the prompt is required. Kling 4.0 also edits a video as the prompt says
     (`mode: "edit"`), with up to ten images.
   - **Characters by name.** `elements` lists the account's characters, environments and props. Pass their names in
     `elements` to `create_video`, `quote` or `create_image`: their images go first, in order, then your own files.
     The answer's `references` gives each image's `@ImageN` tag; name them that way in the prompt, and the
     source video as `@Video1`.
4. **Follow with `jobs`.** Pass the job IDs and `wait_seconds` (up to 50), and call again while they run. A finished
   video's `result` and an image request's `results` are file paths.
5. **Review and show.** `library_search` finds results (newest first, `nextCursor` → `cursor`), `library_get` gives
   them in full (the whole prompt, the inputs in order, the settings), `frames` writes still frames of a result at the
   seconds you name, with `compare_source` or `compare_item` a contact sheet beside what it was made from, so look
   at those instead of guessing. It is free; the source of a history result is read from its Higgsfield link. `library_mark` keeps, rejects or stars results, and `show` opens a job, a page or an
   item's sheet in the app for the person.
   - **Higgsfield history.** `library_search` with `include_higgsfield` also lists the account's history
     (`onHiggsfield`, no file yet; `refresh_higgsfield` reloads it), and `library_download` brings those results
     into the Library. Both are free.
6. **Finish.** `enhance` upscales, reframes, removes a background, dubs or changes the voice of a video on
   Higgsfield, with its own `request_id` and `max_cost`. Two operations run on this Mac instead, free and without
   `max_cost`: `smooth_motion` (`mode` `60fps`, `slow_2x` or `slow_4x`) on a video, and `upscale` with `engine: "mac"`
   on a video up to 1280×720 or an image up to 1920×1080. Prefer them for drafts, small results and frame-rate
   smoothing; `capabilities`' `onDevice` says which this Mac has. They still take a `request_id`, answer with a job
   of kind `on_device` and its `estimatedSeconds`, and `jobs` and `job_action` cancel follow them; the result
   becomes the item's current version, and `library_get` names the version it was made from (`madeFrom`). The
   first Upscale on this Mac answers `needs_person` until the person agrees to macOS downloading its model: call
   `show` with the `item` and `sheet: "upscale_on_mac"` as `next` says, tell the person, and send `enhance` again
   once they agreed. `busy` means a run on that item is going: follow it with `jobs` first. `engine_unavailable`
   means this Mac has no such engine: use Higgsfield instead.
   - **Subtitles.** `subtitles` with `action: "make"`, a `request_id`, and optionally `language` and `engine`
     (`auto`, `built_in`, `parakeet`; `capabilities`' `onDevice.subtitles` lists each one's languages and model)
     hears a video's speech on this Mac, free, and saves the cues on its current version. It answers with a job of
     kind `on_device` and operation `subtitles`; follow it with `jobs`. `needs_person` means only the person can go
     on (agreeing to macOS downloading a language's model, or downloading Parakeet Ultra in Settings › Subtitles):
     call `show` with the `item` and `sheet: "subtitles"`, tell the person, and make again with a new `request_id`
     later. `action: "get"` reads the cues (with `format` also the file's text); `action: "export"` with `format`
     `srt` or `vtt` writes the file into the Exports folder.
   `export` writes takes for Premiere, DaVinci Resolve or Final Cut Pro, and
   `delivery_set` creates, lists and exports delivery sets. An export runs in the app and answers at once (or after
   `wait_seconds`, up to 50) with a `job`: follow it with `jobs` like any job, and read its `files` and `results`
   once it is `done`. If the app was relaunched meanwhile, `jobs` answers `unknown`: look in its `folder` or export
   again. An answer of `still_working` means the app is still on it; send the same call again or call `jobs`.

## Rules

- **Held means tell the person.** A job over your `max_cost`, over what is left of the daily agent budget, over the
  person's cap, whose price isn't known, or that costs more than the person approved, is held (`state: paused`,
  `needsPerson: true`). Don't work around it with another request: tell the person, who can send it from the Queue or
  raise the budget. Only the person can.
- **Reuse `request_id` exactly.** Sending the same `request_id` with the same fields returns the same job and never
  pays twice, so repeat it after a lost answer. The same `request_id` with other fields is refused
  (`request_conflict`). A new request needs a new `request_id`, and so does a retry the app refused.
- **Nothing deletes.** Reject only hides a result in the Library; `job_action` cancels, retries or moves up a job.
  Removing results is the person's call, in the app.
- **The queue is the person's.** `pause_queue` and `resume_queue` pause and resume only agents' jobs not yet sent;
  `resume_queue` never lifts the person's own Pause all.
- **Files are paths on this Mac.** Give absolute paths to your own files (`source.path`, `images`, `inputs`,
  `frames`' `file`); the `jutsu` helper copies their bytes into the app. Paths the app gives back are in its output folder and readable as
  they are. Exports never replace a file.
- **Never ask for credentials.** You never see the API key or the sign-in, and never need them.
- **Topaz is the person's.** A Topaz upscale is refused (`priced_after_run`): its price is known only after it runs.
