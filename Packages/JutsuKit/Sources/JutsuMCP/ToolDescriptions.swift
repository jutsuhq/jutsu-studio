import JutsuAgent

/// What each tool says it does, the `description` of `tools/list`.
extension Tool {
    var about: String {
        switch self {
        case .capabilities:
            """
            What Jutsu Studio can do now: the app version (and the helper's, with helperNote when the helper is older \
            and the MCP server needs a reconnect for this version's tools), how it is connected to Higgsfield (none, \
            apiKey or account) with the account's plan and credits when known, today's agent budget in whole units \
            (usd_cents with an API key, credits on an account: dailyLimit, spentToday, reservedToday for submits not \
            answered yet, remaining, and unlimitedAllowed, whether the person lets agents use the plan's unlimited \
            generations, false for the rest of the day once one was charged anyway; dailyCap and capTakenToday, the \
            person's own daily cap and what it counts today, every job theirs and agents' together, apart from the \
            budget: a job over it is refused with over_cap) and the tool groups this version offers. models: true adds \
            the video models (id, title, modes, resolutions, whether the connection runs it); model: an ID returns \
            only that one, with its limits per mode (seconds, images, whether it needs a style or a source, the \
            resolutions it takes there, and maxVariants, the most variants takes there on this connection, with \
            variantsUnavailable saying why it is 1). image_models: true adds the image models create_image takes (counts, aspect ratios, whether input \
            images are needed, maxInputs, the most inputs it takes, with maxInputsNote when that is a bound because \
            the catalog states none; read when the app connects, window or not, with imageModelsNote saying why and what \
            to do while the connection's own list isn't in), styles: true Restyle's style IDs, voices: true Change Voice's voices. onDevice \
            says what enhance runs free on this Mac: smoothMotion (its modes), upscaleVideo and upscaleImage, each \
            with available, the largest source either way round (maxLongSide, maxShortSide) and its model: none, \
            needs_consent (only the person can agree to macOS downloading it), downloading, ready (a run found it \
            since the app started) or agreed (macOS downloads it at the first run if it isn't here yet). \
            onDevice.subtitles lists the speech models subtitles make takes (engines: built_in, parakeet) with the \
            languages each takes and its model (built_in: needsConsent, the languages whose model only the person \
            can agree to macOS downloading, per language; parakeet: not_downloaded, downloading or ready), and \
            defaultEngine, the person's choice in Settings. window says whether the app has a window open (open; \
            an app the helper started has none until show opens one) and whether it runs in the menu bar \
            (menuBarMode). Free, and never shows a credential.
            """
        case .quote:
            """
            What a video would cost now, with the same parameters as create_video, without uploading or queueing \
            anything: the price in whole usd_cents or credits (null when not known before upload), whether it is \
            exact (an estimate, isExact false, comes with priceNote: Higgsfield quotes the exact price before the job \
            is sent, and the job runs on its own when that is within max_cost and today's budget), what is left of \
            today's agent budget, paysUnlimited (the plan's unlimited generations would pay for it: it costs the \
            budget nothing, and waits for the person unless unlimitedAllowed), and blocker, \
            why create_video would hold or refuse it now, and maxVariants with variantsUnavailable, the most videos \
            one job of it makes and why only one (a style; the plan's unlimited generations, which make one video \
            per job while the person uses them; a connection without variants), and images with minImages and \
            maxImages, the reference images the job has (elements' included) and the most and fewest its model takes \
            in this mode, the server's limits where it states them, else the app's, and aspectRatio, the result's \
            frame (source: it keeps the source clip's orientation; model: the model takes no aspect ratio and picks it \
            itself, with frameNote saying what to check). A source \
            needs end (its start and end in seconds) instead of a file; images may be paths or image_count. Free.
            """
        case .createVideo:
            """
            Queues one video in Jutsu Studio, made exactly as the Create screen would make it and checked by the same \
            rules and model limits. request_id is your own new ID for this request; sending the same request_id with \
            the same parameters again returns the same job and never queues or pays twice, and another request under a \
            used request_id is refused with request_conflict. max_cost {amount, unit: usd or credits} is the most you \
            agree to pay: right before the job is paid for, a price above it, above what is left of the daily agent \
            budget or not known pauses the job (state paused, pauseReason agent_limit) until the person confirms it in \
            the app; so does a job the plan's unlimited generations would pay for while the person doesn't let agents \
            use them (hold unlimited_not_allowed). A job held over_max_cost goes on when the same request_id and \
            parameters come again with a higher max_cost that covers its price, what is left of the budget and the \
            person's cap (no files are sent again); otherwise it stays held, with next saying why. Files (source.path, \
            images) are paths on this Mac, copied into the app. elements names the account's characters and other \
            reference elements (from the elements tool, account only): their images are added first, in the element's \
            order, then images; the answer's references lists every image sent with its @ImageN tag, the N the prompt \
            names it by, and a source is @Video1 (Kling 4.0 reads them as @image_N and @video_1). title names the job in the Queue, the Library and export file names instead of the source's \
            file name. Returns the job; follow it with jobs. With wait_seconds (0–50) the answer comes once the job's \
            price is known (isPriceExact) or it is held or finished, else when the wait runs out, with timedOut; \
            waiting stops nothing.
            """
        case .createImage:
            """
            Makes images in Jutsu Studio, built exactly as the Image side of Create would: model (an ID from \
            capabilities with image_models; the first when left out), prompt, aspect_ratio, count, and inputs, \
            images on this Mac to edit, in order, for models that take them (up to the model's maxInputs; input is \
            the same with one image, never both); elements adds the account's reference elements by name, their \
            images first, and references in the answer tags each image @ImageN; title names the request in the Queue \
            and the images in the Library and their file names instead of the start of the prompt. request_id and \
            max_cost work as in create_video: the \
            same request_id with the same parameters returns the same request and never pays twice. Right before it \
            is sent, a price above max_cost, above what is left of the daily agent budget, over the person's daily \
            cap or not known holds it (state paused, needsPerson) until the person sends it from the Queue. Follow \
            it with jobs: results lists the images' paths once they are saved in Library › Images. While the \
            connection's image models aren't read yet it is refused, retryable, with next saying what to do.
            """
        case .elements:
            """
            The account's reference elements, characters, environments and props, as References › From Higgsfield \
            lists them: id, name (what create_video's and create_image's elements take), category and imageCount when \
            known. query (words of the name), category, limit (at most that many, up to 50; fewer when the account's \
            pages read for one answer run out first); pass nextCursor back as cursor for the next page. Account \
            connection only. Read-only and free.
            """
        case .jobs:
            """
            One place to follow work: video jobs, image requests, exports and runs on this Mac, by ID (ids, up to 20), \
            or the latest agents started (limit, up to 50, newest first; pass nextCursor back as cursor for the page \
            after). Each has kind (video, image, export, delivery_export, on_device), state, pauseReason, hold, \
            needsPerson, progress, price, error and result (the finished video's path, with next saying how to check \
            it with frames, and width, height and duration, read from the file, with frameNote when its shape isn't \
            the source's: scaling it to the source's frame would stretch it); a run on this Mac (on_device) has operation, mode, item, the Library item whose new \
            version it makes, estimatedSeconds and price 0, and is queued, downloading (its model), processing, done, \
            failed or canceled (subtitles' runs have operation subtitles and no mode); an image \
            request's results are its images' paths, an export's results the files written, with folder and files \
            (each done, failed or skipped). An ID Jutsu Studio doesn't know is state unknown with next: an export's ID \
            is forgotten when the app quits. wait_seconds (0–50) waits until everything named has settled (done, \
            failed, rejected, canceled, paused or unknown); a wait that runs out returns the state as it is, with \
            timedOut, and stops nothing. Read-only.
            """
        case .jobAction:
            """
            cancel, retry or run_next a job an agent queued (job: its ID), or pause_queue or resume_queue for every \
            job agents queued that isn't sent yet; the person's own jobs are never touched. retry is refused when \
            the job may already have been charged or its files are gone; resume_queue resumes only what pause_queue \
            paused, never the person's own Pause all or a job paused for its price or the agent limits, which only \
            the person can lift. An image request and a run on this Mac an agent started can only be canceled, which \
            for a run deletes what it wrote so far. Nothing else is deleted.
            """
        case .librarySearch:
            """
            Finds results in the Library on this Mac, videos and images, newest first: query (words of the prompt or \
            title), kind (all, video, image), starred, verdict (unreviewed, kept, rejected), model, mode (videos \
            only), from and to (ISO 8601). Rejected results stay out unless verdict is rejected or \
            include_rejected is true. Each item has its ID, file path, kind, model, mode, aspect ratio, duration, \
            width and height (the current version's frame, when known), price, verdict, star, date, prompt (cut to 200 characters, promptTruncated) and version. limit up to 50; \
            pass nextCursor back as cursor for the next page. include_higgsfield also lists the account's Higgsfield \
            history, as Library › From Higgsfield shows it: those items have onHiggsfield true and no file until \
            library_download brings them here; refresh_higgsfield (with include_higgsfield) loads that history from \
            Higgsfield again first, as the page's refresh does. Read-only and free; never spends credits.
            """
        case .libraryGet:
            """
            The full details of up to 20 Library items by ID (from library_search or a job), rejected ones too: the \
            item as library_search lists it but with the whole prompt; inputs, the files that went in, in the order \
            the job sent them (role source, start_frame, end_frame, reference or edited_from; position, the N of the \
            prompt's @ImageN; file, the path on this Mac when it is here; item, its own Library ID when the Library \
            lists it; onHiggsfield; start and end, the source's range); and settings (resolution, draft, audio, \
            style, length, aspectRatio, paidWithUnlimited, operation for an Enhance result, count for images); and \
            madeFrom, for an item whose current version was made from an earlier one of its own (a run on this Mac, \
            an edit in another app): that version's item, versionId, version and file, to compare or go back. A \
            result only on Higgsfield (include_higgsfield) is there too, as far as the history says it, with no file \
            and next pointing at library_download. IDs no item has are listed in notFound; the rest are answered. \
            Read-only.
            """
        case .libraryDownload:
            """
            Downloads up to 20 results of the account's Higgsfield history (library_search with include_higgsfield, \
            onHiggsfield true) into the Library on this Mac, as From Higgsfield's download does: each keeps its ID \
            and gains a file. Answers per ID, in order, with status downloaded, already_here (it had a file; nothing \
            downloaded) or failed, file and message. An ID the Library doesn't list is not_found and nothing is \
            downloaded. Free; never spends credits, never creates anything on Higgsfield.
            """
        case .libraryMark:
            """
            Sets the culling verdict (keep, reject or clear) and, apart from it, the star (true or false) of up to \
            100 Library items by ID, as the Library's own buttons do. A star on a result the connected account made \
            is also its like on Higgsfield. Marking the same way again changes nothing (changed counts what did). \
            Reject only hides a result in the Library: nothing is deleted or moved to the Trash.
            """
        case .enhance:
            """
            One Enhance operation on a Library result, as the Library's Enhance menu does. On this Mac, free, with no \
            account, max_cost or budget: smooth_motion on a video (mode 60fps, keeping length and sound, or slow_2x \
            and slow_4x, without sound) and upscale with engine mac, 4× a video up to 1280×720 or an image up to \
            1920×1080, either way round, or to target: 1080p, 2k or 4k (the short side 1080, 1440 or 2160 pixels) or \
            a factor such as 2x or 2.5x, more than 1 and at most 4, keeping the source's shape with even sides, so a \
            720×1280 clip at 1080p is 1080×1920; a target the source can't reach within 4×, or isn't larger than, is \
            refused; the result becomes the item's new version (library_get's madeFrom names the \
            one before). Prefer it for drafts, for videos up to 720p and for smoothing motion or frame rate. Runs go \
            one at a time; an item with a run going is refused with busy, a Mac without the engine with \
            engine_unavailable, and an upscale before the person agreed to macOS downloading its model with \
            needs_person: then call show with the item and sheet upscale_on_mac and tell the person. On Higgsfield, \
            paid, on a video: upscale (target 1080p, 2k or 4k; frame_rate 24, 30 or 60; engine standard), reframe \
            (aspect_ratio 9:16, 1:1 or 16:9, results up to a minute), remove_background, dub (language, an ISO 639-3 \
            code) or change_voice (voice, from capabilities with voices); needs a Higgsfield account and max_cost, \
            and the job is checked by the same spending guard as create_video; one whose price isn't known waits for \
            the person. A Topaz upscale is refused (priced_after_run): its price is known only after it runs. \
            request_id works as in create_video for both: the same request_id and parameters return the same job or \
            run. Returns it with its expected seconds for a run on this Mac; follow it with jobs, cancel it with \
            job_action.
            """
        case .deliverySet:
            """
            Library › Delivery Sets. create: a set of Library items (items, their IDs) at their current versions, \
            with an optional name. list: every set, and folders, the folders the person exported sets to. export: \
            writes the set's files still to write with its outputs (a full-size JPEG for images and an H.264 file \
            for videos unless the person changed them) into folder, one of list's folders, or else the output \
            folder's Exports folder. The export runs in the app: it answers at once, or once it finished within \
            wait_seconds (0–50), with job (kind delivery_export), whose ID jobs follows until every file is done, \
            failed or skipped. A wait that runs out stops nothing. Free and local; never replaces a file. \
            Exporting freezes the set's versions.
            """
        case .export:
            """
            Exports video results for editing, as the result page's Export for Editing does: preset premiere, \
            davinci_resolve or final_cut_pro (ProRes 422, MOV) or editing_h264, with a JSON sidecar of the job \
            unless sidecar is false, into the output folder's Exports folder. The export runs in the app: it \
            answers at once, or once it finished within wait_seconds (0–50), with job (kind export), whose ID jobs \
            follows with progress and each file's path, or why it failed or was skipped. A wait that runs out stops \
            nothing. Free and local; never replaces a file.
            """
        case .frames:
            """
            Writes still frames as PNG files, to look at a result without a video player: item (a Library ID) or \
            file (a video or an image on this Mac) at times, 1–12 seconds from its start, the exact frame at each. \
            To compare, give one of compare_item, compare_file or compare_source (true: the item's own source clip, \
            at the same times from the start of the range it used, so the swap and what it swapped line up): its \
            frames at the same times are written too, with a contact sheet, a row per clip (item on top) and a \
            column per time; several times without a comparison get a sheet as well. Answers with folder, the \
            output folder's Exports folder, frames (clip main or compare, time, file) and sheet. An image has one \
            frame whatever the time; a time past a video's end is refused. Free; never replaces a file. The source \
            of a result only on Higgsfield is read from its Higgsfield link.
            """
        case .subtitles:
            """
            Subtitles of a video in the Library, heard from its speech on this Mac, free, with no account, max_cost or \
            budget, as the Subtitles sheet and editor make them: cues of at most two 42-character lines, 1 to 7 \
            seconds each, saved on the item's current version (a later version starts without them). make: \
            request_id as in enhance (the same request_id and parameters return the same run, never a second one), \
            language (en-US, de… from capabilities' onDevice.subtitles; the person's last or system language when \
            left out) and engine (auto: macOS's SpeechTranscriber, else Parakeet Ultra once downloaded, else \
            Dictation; built_in; parakeet; the person's default when left out). It returns the run (kind on_device, \
            operation subtitles); follow it with jobs and cancel it with job_action. Runs go one at a time; an item \
            with a run going is refused with busy; a language the engine doesn't take with invalid_request; and with \
            needs_person when only the person can go on: agreeing to macOS downloading that language's model (the \
            person agrees per language), or \
            downloading Parakeet Ultra in Settings › Subtitles; then call show with the item and sheet subtitles and \
            tell the person. A video without speech fails with "No speech found". get: the current version's \
            language, model and cues (start, end, text, the lines joined by a newline), as the person may have \
            edited them; with format (srt or vtt) also text, the file as it would be written. export: writes them as \
            format into the output folder's Exports folder, never over a file, and answers with file. get and \
            export of a version without subtitles are refused with not_found.
            """
        case .show:
            """
            Opens a page of Jutsu Studio for the person and brings its window to the front, opening the window when \
            none is: page (create, queue, \
            library or settings), or job, a job ID, which opens a finished job's result in Library and any other \
            job's row in the Queue, or item, a Library item ID, with sheet upscale_on_mac, which opens its Upscale on \
            This Mac sheet, where the person agrees to macOS downloading the model (engine_unavailable on a Mac \
            without the engine), or sheet subtitles, a video's Subtitles sheet, where the person agrees to the \
            download of a language's model or sees that Parakeet Ultra needs downloading; needs_person while the \
            person has another sheet open. Give exactly one of page, job \
            or item. Changes nothing but what the window shows.
            """
        }
    }
}
