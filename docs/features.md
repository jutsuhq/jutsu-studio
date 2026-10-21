# Jutsu Studio features

Everything the app does, by area. The [README](../README.md) has the short version.

Some features depend on how you connect. **Account** means a Higgsfield account connected through Higgsfield's MCP server (plan credits); **API key** means your own key from the [Higgsfield console](https://console.higgsfield.ai) (pay as you go). Features marked with neither work on both.

## Models and modes

| Model | What it makes | Connection |
|---|---|---|
| Genjutsu | Motion transfer, object swap and restyle of a source video | Both |
| Seedance 2.5 | Motion transfer; a clip from a prompt and images with no source video; a clip between a start and an end frame; Edit and Extend of an existing video; standard or high bitrate | Both |
| Kling 3.0 Motion Control | Motion transfer, Standard or Pro quality, with the option to keep the video's background. Keeping the original sound and the character orientation need an API key | Both |
| Kling O3 video reference | Motion transfer from a reference video | API key |
| Kling O3 Edit | Edit of an existing video as the prompt says, with up to four images, Standard or Pro quality | Both |
| Kling 2.6 Motion Control | Motion transfer, Standard (480p/720p) or Pro (1080p), with the character orientation | API key |
| Wan 3.0 and Wan 3.0 Prime | Motion transfer from a reference video and up to ten images, 2–30 s, with an optional soundtrack | Both |
| Wan 2.7 | Motion transfer from a reference video and up to four images, 2–10 s, 720p or 1080p, 16:9 or 9:16 | API key |
| Cinema Studio 4.0 | Motion transfer from a reference video and up to eight images, 4–30 s, 480p or 720p, with an optional soundtrack. Direction sets the camera, lens, aperture, camera movement, genre, era, lighting, pacing and color palette, each on Auto (the director picks) until set; Direction needs an API key | Both |
| MiniMax H3 | Motion transfer from a reference video and up to five images, 5–15 s, at 2K | Both |
| MiniMax H3 Max | Motion transfer from a reference video and up to five images, 5–15 s, 480p or 768p | Account |

- Each mode shows only the fields it needs, and a model the connection can't run isn't offered.
- Model limits (lengths, resolutions, image counts) come from Higgsfield's live model catalog, with built-in values as a fallback.
- Each model offers only the resolutions it supports. A model whose price Higgsfield doesn't publish shows "Price unknown", and a daily cap asks before it starts; one for which Higgsfield publishes only a range shows "up to" the top of it.
- **Account:** a plan's unlimited generations are used for a model when the account has them.

## Create

- Create has a Video side and an Image side, switched next to the page title. Each side keeps its own draft, so switching never loses either.
- Image side: make still images from a prompt with the connection's image models (model, aspect ratio, how many, an optional image to edit), with the price on Generate. It doesn't block the window: requests keep running while you switch side or page, and their results show under the form, in the Queue and in Library › Images.
- Open a video or images from Finder, drop them on the window or the Dock icon, paste them, or import them from a link.
- Pick a 4–30 s range; only that range is uploaded and billed.
- Cut several ranges from one clip and queue them in one click with one total price.
- Reference images: add up to 8, reuse images and clips you uploaded to Higgsfield before, or generate new ones from a prompt in the References section: pick several results, open one large, and add them in the order picked.
- **Account:** use your Higgsfield reference elements as references, and save a batch character to Higgsfield as a character element (More › Save to Higgsfield…), free, for use here and in the web app.
- **Account:** Create Character: design a person or an animal from a preset or traits (one collapsed row per trait group, open it to pick), a description, an optional face and up to 3 style references, see Higgsfield's exact price on Generate, and make 1–4 character sheets; pick a sheet under References › From Higgsfield › Characters to keep the character the same across videos.
- **Account:** start from a clip in the Genjutsu Motion Library.
- The restyle preset gallery with previews, search, starred favorites and recent styles on top, cached on the Mac and refreshed on launch or on demand.
- Prompt history with search and stars.
- Templates: save a character, preset and prompt, or an image request (model, aspect ratio, count, prompt and the image to edit), and use them again from the Templates button or File › New from Template. The current side's templates are listed first, and an image template opens the Image side.
- Keep, mute or fade out the source audio on the result, or have Seedance make a soundtrack.
- Both Create drafts survive a relaunch, and Undo brings the video draft back when something replaces it.

## Input prep on the Mac

- MOV, HEVC and ProRes are transcoded with AVFoundation, so there's no re-exporting to fit the API.
- Range trimming, HEIC to JPEG, fitting under the 200 MiB upload limit, and an upscale offer for object-swap frames that are too small. When something can't be fixed, the app says why.
- Identical inputs aren't uploaded twice.

## Price and spending

- Every Generate button shows the job's price before you click it; when a price is unknown, the app asks first.
- **Account:** the price is Higgsfield's own quote, asked for free as you change the form and before anything is uploaded, for every model that takes a length (Seedance from a prompt, frames or Extend, Kling 3.0, Wan 3.0, Wan 3.0 Prime, Cinema Studio 4.0, MiniMax H3 and H3 Max). Genjutsu, Seedance Edit and Kling O3 Edit are priced by their source video, so until it is uploaded they show an estimate, and Higgsfield quotes the uploaded file before the job starts. Variants multiply the price. Only a Topaz upscale has no price before it runs: it says "Price shown after the run", asks you to agree, and once it finishes its price is read from your credit history (left unknown when no single charge matches it).
- **API key:** the list price from open.higgsfield.ai before upload, or "up to" the top of a range where only that is published (Cinema Studio 4.0, Kling O3, Kling O3 Edit); Seedance from a prompt, which has nothing to upload, gets Higgsfield's own quote as you change the form. Higgsfield quotes every job's uploaded files before it starts.
- Quick Preview: a cheap draft (480p by default, optionally only the first seconds) before the 720p or 1080p final.
- **Account:** a Seedance 2.5 draft at 480p is Higgsfield's native draft, at the normal 480p price. For seven days after it finishes, the draft's page shows until when, and Finalize in 1080p has Higgsfield render that draft at 1080p for a third of a fresh 1080p render (80 credits instead of 240 for 15 s), quoted before you confirm. The final is linked to its draft in the Library.
- An optional daily spend cap (USD with an API key, credits on an account) with a confirmation above it, and a low-credits warning.
- A spending breakdown for today, 7 and 30 days by mode, resolution and draft/final, with CSV export.
- **Account:** the credit history straight from Higgsfield.
- Failed, moderation-rejected and canceled jobs are never billed.

## Queue

- Jobs run in the background within the account's concurrency limit, read from Higgsfield automatically.
- Every job has one idempotency key, so a retry, a double click or a restart never pays twice.
- Pause and resume the whole queue, move an urgent job to the front with Run next, cancel a queued job or a whole batch.
- Duplicate a job; the app shows what Duplicate and Render final queued and at what price.
- Retries show on the job, and a job that keeps failing before submit is paused instead of looping.
- Failed, rejected and canceled jobs stay in the Queue until you remove them; copy a failed job's IDs for support.
- The queue resumes after a restart or a dropped connection, and jobs being submitted finish before the app quits.

## Library

- Every result is downloaded to `~/Movies/Jutsu Studio/Videos` as soon as it's ready, with its source, references, prompt, cost, request IDs and how long it queued and rendered. Higgsfield's links expire; the library doesn't, and it opens offline.
- Your Higgsfield history next to local results. Styles made outside Jutsu Studio aren't listed: Higgsfield's history doesn't return them. Once a result is downloaded, its length and frame size are read from the file itself, not from what the job asked for, so the card, the player, Compare and Enhance use the real ones.
- Search, filters and stars; on an account, a star is the video's like on Higgsfield.
- A before/after player against the source and Quick Look with Space.
- Compare two takes side by side and pick the winner.
- The draft → final chain of each result, with one-click Render final or Edit Inputs. On an account, a Seedance draft's 1080p final, single or for a batch's starred drafts, is Finalize in 1080p while its seven days last.
- Select several results and act on them at once; render finals for a batch's starred drafts.
- Cull from the keyboard: the arrow keys move through the grid, Space previews, P keeps, X rejects and U clears (changeable in Settings › Shortcuts), ⌘Z takes back the last one. It works on the result page too, and on a selection, whose bar says how many results it acts on. Rejected results are hidden from every tab and search until Show rejected is on; nothing is deleted.
- The variants of one generation fold into one card with their count; Show Variants spreads them out, Make Primary picks the card's face, and Compare Variants steps through them.
- **Account:** Score Variants in a batch's comparison, free: the Virality Predictor's overall score, viral potential, hook (0–3 s), engagement, sustain and peak second for each result, with its per-frame line and Higgsfield's dashboard.
- Drag results out of the app into other apps, or share them.
- Save a result's source video and reference images back to the Mac.
- Images: every image Generate… makes is saved to the `Images` folder of the output folder as soon as it's ready, named by date and prompt, and listed in Library › Images with search, Quick Look, Use as Reference, Show in Finder, drag out and Move to Trash. An image whose file can't be found, for example on a drive that isn't connected, stays listed as unavailable and comes back with its drive; only Remove from Library takes it off.
- Make Video… on an image (its menu, the selection bar or its Details…) opens Create's video side with it and asks what the image is where the model takes more than one role: start frame, end frame or reference. Only the roles the model declares are offered; two images become a start and an end frame in one step. Switching the model or tab in Create checks the roles again and says what changed: frames the model doesn't take become references, and images over its limit come back with Undo.
- A video's page shows "Made from" with the exact image versions and their roles; an image's Details… shows its prompt, what it was made from and "Used in" with every video made from it, and each side opens the other. A source that was removed or whose file is gone stays, marked unavailable.
- A 5-second silent MP4 preview small enough for a messenger.
- Portrait results are shown whole in the grid.
- **Account:** Enhance a result: Upscale (standard or Topaz), Reframe, Remove Background, Dub and Change Voice, each with its price on screen before it's queued.
- Join with Original… on a Seedance Extend result: the source selection followed by the new part as one MP4, with each part's own sound. The new part starts on the source's last frame, so that frame is shown once.

Images and videos share one persistent material catalog. It retains versions, the actual generation parameters when known, account-scoped remote identity, variant groups and links to the exact inputs used. A local Extend join is registered as a derived result. Missing files stay listed; originals and earlier versions are not overwritten by history refreshes.

## Export for editing

- One click to ProRes 422 for Premiere Pro, DaVinci Resolve or Final Cut Pro, or high-quality H.264.
- Constant frame rate matching the source, and take names that sort in order (`rooftop_00m04.0s-00m10.0s_restyle_Film Noir_v2.mov`).
- An optional JSON sidecar with the prompt, inputs and request ID.

## Delivery sets

- New Delivery Set on a selection of videos and images makes a named set of their exact versions. Library › Delivery Sets lists every set with its status: not exported, or exported with the date and folder, plus a note and a review link (text only; nothing is uploaded).
- Export a set in several outputs at once: images as JPEG, PNG or HEIC at a chosen long edge, quality and color space (sRGB or Display P3), videos with the editing presets. PNG keeps transparency; JPEG and HEIC are flattened onto a background you pick. Each output can crop to an aspect ratio, and each item's frame can be moved before export.
- Files are named `<set>_<NN>_<item>_<output>.<ext>` with a JSON manifest of the exact versions next to them. Files made by others are never replaced.
- Each file shows done, failed or skipped (an item whose file isn't on this Mac). Retry Failed writes only the failed ones; after fixing one item's crop, Export Pending writes only that item's files.
- A set is frozen once exported: later edits of its items never change what it holds. New Set from This One starts the next round with the newest versions.
- Edit in… opens a copy of an image or video in another app (Photoshop, Preview…), never the original. Drop the edited file on its card or use Import as New Version…: it is copied into the output folder and becomes the next version of the same item, linked to the exact version it was made from.

## Runs in the background

- Close the window and the jobs keep going.
- Live status and credits in the menu bar (can be hidden, optionally with the active job count), with actions on results and jobs right from the menu.
- A Dock badge, and notifications when a job is done, failed, rejected or paused, each with its own switch and an optional sound.
- Open at login, and a warning before quitting with jobs, image requests or character sheets in flight. Closing the last window keeps the app running for them, and quitting waits a few seconds for requests being sent and images being saved.
- Downloads resume where they stopped, and a download pauses on a full disk instead of failing a paid job.

## Settings

- Default mode, final and draft resolution.
- Result file name patterns with ready-made templates and a live example.
- Keyboard shortcuts you can change.
- A Storage tab showing what the library, downloaded inputs and caches take on disk, which moves old drafts to the Trash.
- Software Update: checks GitHub releases once a day, or with Check for Updates… in the app menu and Settings › General; downloads, verifies and installs the new version and relaunches. Automatic download is optional.

## Agents

- Lets an AI agent on your Mac, such as Claude Code, work with the app through the bundled `jutsu` helper, a Model Context Protocol server. Add it with the line Settings › Agents shows.
- Off until you turn on Allow agents. Turning it off refuses the agent's next request and stops nothing already running.
- A daily agent budget, apart from the daily cap: dollars with an API key, credits with an account. 0 by default.
- For now an agent can read what the app offers (the connection, credits, budget and models) and open a page or a job for you. It can't start jobs, spend, delete anything or see your key or sign-in.

## Connection and privacy

- Two ways to connect: your Higgsfield account (OAuth in your browser; the app never sees your password) or your own API key.
- Keys and tokens live in the macOS Keychain; logs redact credentials and signed URLs.
- No Jutsu server, no account of ours, no markup, no telemetry. The app talks to `api.higgsfield.ai` and `mcp.higgsfield.ai` directly, and to `github.com` for updates.
- The library and settings work offline; the queue pauses without a network and resumes when it's back.

## Accessibility

- Full VoiceOver labels and Reduce Motion support throughout the app.
