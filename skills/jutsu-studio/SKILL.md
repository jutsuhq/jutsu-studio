---
name: jutsu-studio
description: Make, find and deliver Higgsfield videos and images with the Jutsu Studio app on this Mac, through its jutsu MCP server. Use when asked to generate a video or image with Jutsu Studio, follow or cancel its jobs, search, keep, reject or star Library results, upscale, reframe, dub or change the voice of a result, or export results for editing or delivery.
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

## How to work

1. **Capabilities first.** Call `capabilities`. It shows the connection, today's budget (`remaining`) and the tool
   groups. Ask for `models`, `image_models`, `styles` or `voices` when you need them; they come from what the app last
   read, never a network call.
2. **Quote before you create.** `quote` a video with the same fields you mean to send, and tell the person the price.
3. **Create with a `max_cost`.** `create_video` or `create_image` with a new `request_id` of your own and a `max_cost`
   (`{amount, unit}`, `usd` or `credits`, matching the connection) no lower than the quote. Use a cheap draft mode when
   it fits the task (`draft: true` on models that have one, a lower resolution, fewer variants), and make the full
   version once the person likes the draft.
4. **Follow with `jobs`.** Pass the job IDs and `wait_seconds` (up to 50), and call again while they run. A finished
   video's `result` and an image request's `results` are file paths.
5. **Review and show.** `library_search` finds results (newest first, `nextCursor` → `cursor`), `library_mark` keeps,
   rejects or stars them, and `show` opens a job or a page in the app for the person.
6. **Finish.** `enhance` upscales, reframes, removes a background, dubs or changes the voice of a video, with its own
   `request_id` and `max_cost`. `export` writes takes for Premiere, DaVinci Resolve or Final Cut Pro, and
   `delivery_set` creates, lists and exports delivery sets.

## Rules

- **Held means tell the person.** A job over your `max_cost`, over what is left of the daily agent budget, over the
  person's cap, or whose price isn't known, is held (`state: paused`, `needsPerson: true`). Don't work around it with
  another request: tell the person, who can send it from the Queue or raise the budget. Only the person can.
- **Reuse `request_id` exactly.** Sending the same `request_id` with the same fields returns the same job and never
  pays twice, so repeat it after a lost answer. The same `request_id` with other fields is refused
  (`request_conflict`). A new request needs a new `request_id`, and so does a retry the app refused.
- **Nothing deletes.** Reject only hides a result in the Library; `job_action` cancels, retries or moves up a job.
  Removing results is the person's call, in the app.
- **Files are paths on this Mac.** Give absolute paths to your own files (`source.path`, `images`, `input`); the
  `jutsu` helper copies their bytes into the app. Paths the app gives back are in its output folder and readable as
  they are. Exports never replace a file.
- **Never ask for credentials.** You never see the API key or the sign-in, and never need them.
- **Topaz is the person's.** A Topaz upscale is refused (`priced_after_run`): its price is known only after it runs.
