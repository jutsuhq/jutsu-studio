# Jutsu Studio — architecture

Native macOS app in Swift. This document fixes the module layout, the main types and the data flow. API facts come from the [Higgsfield docs](https://docs.higgsfield.ai/docs/models/genjutsu).

## 1. Baseline

| Decision | Choice | Why |
|---|---|---|
| Platform | macOS 14 Sonoma+, universal binary | `@Observable`, SwiftData, `.inspector`, `MenuBarExtra` are all 14+ |
| Language | Swift 6, strict concurrency | The job engine is concurrent by nature; data races must be compile errors |
| UI | SwiftUI, AppKit only through `NSViewRepresentable` where SwiftUI has gaps (`AVPlayerView`) | Native look, little code |
| Media | AVFoundation, Core Image, ImageIO | No ffmpeg, no codec licensing, hardware encoders |
| Storage | SwiftData for history, files on disk for media, Keychain for secrets | All system frameworks |
| Networking | `URLSession` async/await | Uploads, downloads, polling, MCP HTTP transport |
| Auth UI | Default browser + loopback redirect (Network.framework) | OAuth in the browser the user is signed in to; RFC 8252 §7.3 |
| Tests | Swift Testing | Ships with Xcode 16 |
| Third-party code | Sparkle 2, app target only | Software Update for a sandboxed app outside the App Store: signed appcast, XPC installer. Everything else is system frameworks; the MCP client is our own (§5.3) |

## 2. Layout

One thin app target plus two local Swift packages: `JutsuKit` for the app's logic and `HiggsfieldKit` for the Higgsfield clients. Logic lives in the packages so it builds and tests without the app and without a simulator.

```
project.yml                   XcodeGen spec; JutsuStudio.xcodeproj is generated, not committed
JutsuStudio/                  app target: scenes, views, app model, assets, entitlements
JutsuCLI/                     the `jutsu` helper agents run (`jutsu mcp`), bundled at Contents/Helpers/jutsu
Packages/JutsuKit/
  Package.swift
  Sources/
    JutsuCore/                pure domain: models, pricing, rules, state machine. No I/O
      Resources/pricing.json  bundled list prices
      Resources/models.json   the video models (VideoModelCatalog): modes, limits, Create controls, endpoints,
                              account model IDs, credit rates; titles in Models.xcstrings
    Secrets/                  Keychain wrapper
    HiggsfieldProviders/      both connections as GenerationProviders over HiggsfieldKit: JobSpec to requests,
                              HiggsfieldError to ProviderError, account models and their prices
    MediaKit/                 AVFoundation pipeline: probe, trim, transcode, upscale, thumbnails, images, audio mux
    Persistence/              SwiftData models, ModelActor stores, file layout
    JobEngine/                queue, scheduler, slots, polling, downloads, resume
    Presentation/             UI logic without UI: ConnectionStore, form validation, user-facing messages
    JutsuAgent/               the agent socket: wire types, framing, listener, client, inbox (§12)
    JutsuMCP/                 the MCP server `jutsu mcp` runs: JSON-RPC over stdio, tools, finding the app (§12)
  Tests/                      one test target per module, plus JutsuTestSupport (gated waits shared by suite tests)
Packages/HiggsfieldKit/       the Higgsfield clients, with no app types: update them when Higgsfield changes
  Sources/
    HiggsfieldCore/           HiggsfieldError, GenerationStatus, the URLSession transport and URL.isHTTPS, shared with
                              JobEngine's downloader
    HiggsfieldAPI/            REST client for api.higgsfield.ai (API key): workflows, uploads, presets
    HiggsfieldMCP/            OAuth + MCP client for mcp.higgsfield.ai (account login), and HiggsfieldAccount:
                              the tools as typed calls (generate, cost, upload, status, balance)
  Tests/                      contract tests per client; HiggsfieldTestSupport (stub HTTP host and MCP server)
scripts/                      lint, format, architecture check, Linux tests, release (see CONTRIBUTING.md)
packaging/homebrew/           Homebrew cask template, versioned by scripts/update-cask.sh
```

Dependency direction (arrows = "imports"):

```
App ──► JobEngine ──────────────────────────────► JutsuCore (ports: GenerationProvider, JobRepository, MediaPreparing, Connectivity),
 │                                                 HiggsfieldCore (transport only)
 ├──► Persistence, MediaKit (implement the ports) ─► JutsuCore
 ├──► Presentation (ConnectionStore + its ports) ──► JutsuCore
 ├──► Secrets (adapter for Presentation's ports) ──► JutsuCore
 ├──► HiggsfieldProviders (GenerationProvider adapters) ──► JutsuCore, HiggsfieldKit
 └──► JutsuAgent (the agent socket's app side)

jutsu (JutsuCLI) ──► JutsuMCP ──► JutsuAgent, HiggsfieldMCP (JSONValue only)
```

`HiggsfieldKit` imports nothing of JutsuKit. It speaks Higgsfield's terms (workflows, model IDs, media IDs, `HiggsfieldError`), and `HiggsfieldProviders` translates between them and the app's (`JobSpec`, `RemoteJob`, `ProviderError`). A change on Higgsfield's side lands in `HiggsfieldKit` and its contract tests; the app changes only when the change means something to it. There is no published OpenAPI document, so the clients are written by hand rather than generated.

- `JutsuCore` imports nothing but Foundation. It owns the `GenerationProvider` protocol and the `Credential` value type, so the engine and the providers never import each other: the app builds the provider for the active connection and hands it to the engine.
- `JutsuCore`, `HiggsfieldProviders`, `JobEngine`, `Presentation` and all of `HiggsfieldKit` are portable (Foundation only, `FoundationNetworking` on Linux) and are tested on Linux in Docker. The engine reaches storage, media and connectivity only through protocols ("ports") in `JutsuCore`; `Persistence` (SwiftData) and `MediaKit` (AVFoundation) implement them, and the app target wires them together with an `NWPathMonitor` connectivity source. Only the Apple-framework adapters are macOS-only in `Package.swift`.
- `HiggsfieldCore` (Foundation, `FoundationNetworking` on Linux) holds the one transport: `URLSession.send`, the `HTTPURLResponse` cast and `isSuccess`, and `URL.isHTTPS`, which every URL a server hands out must pass. Each caller names the error a transport failure becomes: the clients throw `HiggsfieldError.network`, JobEngine's downloader `ProviderError.network`. JobEngine imports `HiggsfieldCore` for this only, which keeps networking out of `JutsuCore`.
- Portable modules guard `os.Logger` with `#if canImport(os)`.
- Allowed framework imports per module are enforced by `scripts/check-architecture.sh`. Nothing imports the app target.

## 3. Domain (JutsuCore)

```swift
enum Mode: String, Codable, Sendable { case motionTransfer, restyle, objectSwap, edit, extend }  // edit, extend: Seedance only
enum Resolution: String, Codable, Sendable { case p480 = "480p", p720 = "720p", p768 = "768p", p1080 = "1080p", k2 = "2K" }  // 768p, 2K: MiniMax only

struct JobSpec: Codable, Sendable, Hashable {
    var mode: Mode
    var source: SourceClip            // local file + selected range + upscale flag
    var references: [LocalImage]      // ordered, 0…8 depending on mode
    var presetID: UUID?               // restyle only
    var prompt: String                // ≤ 10 000 chars, "" not nil
    var resolution: Resolution
    var isDraft: Bool
}

enum Cost: Sendable, Hashable {       // a job is paid in one unit, never mixed
    case usd(Decimal, isEstimate: Bool)
    case credits(Int, isEstimate: Bool)
}
```

Pure rules, each a small function with tests:

- `Validation.check(spec) -> [ValidationIssue]` — duration 4–30 s, image counts (`Mode.limits`), preset required, 409 600 px for swap unless upscale is allowed, prompt length in Unicode scalars. `Validation.upscaledSize(width:height:)` gives the swap upscale target.
- `Pricing.cost(for: spec) -> Cost` — billed seconds = `ceil(duration)`, rates from `pricing.json` as `Decimal`. This is the preliminary price; a provider that can quote the uploaded request sets `Job.serverPrice`, and `Job.price` uses it from then on.
- `Budget.allows(cost:committedToday:cap:) -> BudgetDecision` — committed = finished today + everything in flight, so queueing can't bypass the cap. Credits are never capped. A job paid from the plan's unlimited allowance (`JobSpec.usesUnlimited`, decided by the provider at enqueue and cleared when the submit answer says it cost credits) isn't counted, quoted or checked.
- `Budget.refinedPriceNeedsConfirmation(...)` — a server price asks the user again only when it goes over the cap where the preliminary price did not, and the user hasn't already agreed to at least that much.
- `JobState` + `JobState.transition(state, event) -> JobState?` — the whole lifecycle in one `switch`; `nil` means the event can't happen in that state, a programming error caught in tests.
- `FailureReason` — why a job failed: the app's own reasons are cases (deadline, outcome unknown, out of disk space…), stored as a code and worded by Presentation when shown, so a row reads in the language the app runs in now; a server's or provider's text is `.message`, stored as it came.

```
preparing → uploading → waitingForSlot → queued → processing → downloading → done
                         ↺ concurrency limit   ↘ (poll skipped in_progress) → downloading
preparing | uploading | waitingForSlot → paused(reason) → resume → preparing (cached, so cheap)
                                          (keptFailing: retried past the bound before submit)
downloading + disk full → paused(notEnoughDiskSpace) → resume → downloading   (partial file and request kept)
paused(connectionNeedsAttention) → pause all → paused(byUser)   (only the user resumes it)
queued | processing + 401: state unchanged, engine stops polling until the connection is back
preparing … queued, paused → cancel → canceled        (not once processing: the API can't cancel)
any active state except paused → failed;  queued | processing → rejected (nsfw)
failed | canceled → retry → preparing;  failed | canceled → retry download → downloading
failed (past the deadline, request kept, not charged) → check again → queued   (polls the same request)
```

## 4. Providers: one protocol, two logins

The queue, library and UI never talk to Higgsfield directly. They talk to the provider of the one active connection.

```swift
protocol GenerationProvider: Sendable {
    var kind: ProviderKind { get }                          // .apiKey, .account
    func capabilities() async throws -> Capabilities        // modes, resolutions, cost unit, max concurrency
    func presets() async throws -> [StylePreset]
    func estimate(_ spec: JobSpec) async throws -> Cost     // preliminary, before upload
    func serverEstimate(_ spec: JobSpec, inputs: RemoteInputs) async throws -> Cost?  // nil: can't quote
    func upload(_ file: PreparedFile) async throws -> RemoteAsset
    func submit(_ spec: JobSpec, inputs: RemoteInputs, idempotencyKey: UUID) async throws -> RemoteJob
    func status(_ job: RemoteJob) async throws -> RemoteStatus
    func cancel(_ job: RemoteJob) async throws
    func balance() async throws -> Balance?
}
```

| | `HiggsfieldAPIProvider` | `HiggsfieldMCPProvider` |
|---|---|---|
| Login | Key ID + secret pasted once | "Connect your Higgsfield account" (OAuth 2.1 + PKCE) |
| Pays with | Prepaid API balance, USD | Subscription credits |
| Transport | REST, `Authorization: Key id:secret` | MCP Streamable HTTP, `Authorization: Bearer <token>` |
| Upload | `POST /files/generate-upload-url` → presigned PUT | Whatever the server's tools offer; discovered at runtime |
| Modes | All three, documented | Whatever `tools/list` exposes; unknown until checked |
| Cost | `pricing.json` before upload ("Estimate"); `POST /estimate/{model}` with the exact submit body after upload, before submit ("Price from Higgsfield") | Server estimate only, shown as "estimate" |
| Polling, cancel | `status_url` / `cancel_url` from the submit answer when HTTPS on the API host, else `/requests/{id}/…` | Status and cancel tools |
| Balance | None: the public REST docs have no balance endpoint, so no row is shown | The balance tool, when `tools/list` has one |
| ToS | Allowed (§11) | Explicitly allowed for third-party MCP clients (§11.13) |

Capabilities drive the UI: a mode the connection can't run is disabled with the reason, and the cost line shows `$` or credits depending on the connection.

### Accounts

`ConnectionStore` (`@Observable`, `@MainActor`, in `Presentation`) holds exactly one connection or none. It reaches Keychain and the network only through small protocols (`CredentialVault`, `ConnectionServices`), which the app implements with `Secrets`, `HiggsfieldAPI` and `HiggsfieldMCP`, converting the SDK's `TokenSet` to the stored `OAuthTokens`; that keeps the state machine tested on Linux. There is no per-job choice of how to pay: switching means signing out (credential deleted from Keychain) and connecting the other kind. Jobs still in flight under the old connection pause until it comes back. Non-secret metadata (kind, display name, plan) goes to `UserDefaults`; the secret goes to Keychain. `Credential` lives in `JutsuCore`; `Secrets` only stores it:

```swift
enum Credential: Codable, Sendable { case apiKey(id: String, secret: String); case oauth(OAuthTokens) }
```

Keychain item: `kSecClassGenericPassword`, service `com.jutsustudio.connection` (`com.jutsustudio.connection.debug` in Debug builds, so a release build never meets an item it isn't trusted to read and macOS never asks for the keychain password), account `active`, not synchronizable. The item lives in the file-based login keychain (`KeychainStore` doesn't set `kSecUseDataProtectionKeychain`), so the `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` it passes has no effect there; access is governed by the item's ACL, which trusts the app's code signature. Nothing secret in `UserDefaults`, SwiftData or logs.

## 5. Account login over MCP (HiggsfieldMCP)

### 5.1 What the server advertises (checked 2026-10-13)

The raw documents are the test fixtures in `Packages/HiggsfieldKit/Tests/HiggsfieldMCPTests/Fixtures.swift`.

- `POST https://mcp.higgsfield.ai/mcp` without a token → `401`, body `{"error":"Unauthorized"}`, `WWW-Authenticate: Bearer resource_metadata="https://mcp.higgsfield.ai/.well-known/oauth-protected-resource/mcp", scope="openid email offline_access"`.
- Protected resource metadata (same body at `/.well-known/oauth-protected-resource/mcp` and `/.well-known/oauth-protected-resource`) lists two authorization servers, `clerk.higgsfield.ai` and `fnf-device-auth.higgsfield.ai`. Scopes: `openid email offline_access`. The `higgsfield_auth_hints.options[]` extension maps `flow: authorization_code_pkce` to clerk (`potential_clients`: anthropic/claude clients) and `flow: device_code` to fnf-device-auth.
- `clerk.higgsfield.ai/.well-known/oauth-authorization-server`: `/oauth/authorize`, `/oauth/token`, `/oauth/register`, **and its own `/oauth/device_authorization`**; grants `authorization_code`, `refresh_token`, `device_code`; PKCE `S256`; `client_id_metadata_document_supported: true`; `authorization_response_iss_parameter_supported: true` (so the redirect must carry `iss`, and it must name clerk, RFC 9207); public clients (`none`) allowed.
- `fnf-device-auth.higgsfield.ai` returns `404` on both `/.well-known/oauth-authorization-server` and `/.well-known/openid-configuration`. Discovery therefore skips a server whose metadata can't be read and uses the next one that supports the grant.
- clerk's dynamic registration drops the `device_code` grant: asked for it, `/oauth/register` answers with `grant_types: ["authorization_code", "refresh_token"]`, and `/oauth/device_authorization` then refuses the client ("does not have the device_code grant"). So the app neither registers for the grant nor offers device code sign-in.
- `mcp.higgsfield.ai/.well-known/oauth-authorization-server` also exists (`/oauth2/authorize`, `/oauth2/token`, `/oauth2/register`, no device endpoint), but `authorization_servers` doesn't list it, so discovery ignores it.

### 5.2 Flow

1. **Discover** — read both metadata documents at sign-in; never hard-code endpoints.
2. **Identify the client** — by the Client ID Metadata Document when the server advertises `client_id_metadata_document_supported`: the `client_id` is `https://jutsuhq.github.io/jutsu-studio/oauth-client.json`, which GitHub Pages serves from [`docs/oauth-client.json`](docs/oauth-client.json) (`Higgsfield.clientMetadataDocument`; CONTRIBUTING, "OAuth client metadata"). Otherwise dynamic client registration (RFC 7591). Registration is not idempotent, so the issued `client_id` and its issuer are stored with the tokens in Keychain and reused on the next sign-in at the same issuer. A sign-in registers again only when no tokens for that issuer are stored: the first sign-in, after sign-out, or at another issuer. Tokens keep the `client_id` they were issued to, so refreshing tokens from an earlier registration still works.
3. **Authorize** — PKCE S256, `state`, `resource=https://mcp.higgsfield.ai/mcp` (RFC 8707), redirected to a loopback URI (RFC 8252 §7.3): the app listens on `http://127.0.0.1:<port>/callback`, using the first free of three fixed ports that are all registered as redirect URIs, and opens the authorization URL in the default browser. The browser tab shows a "return to Jutsu Studio" page and the app comes back to the front. While it waits, the sign-in sheet shows the page's URL with "Open Again" and "Copy Link", so a browser that didn't come up doesn't end the sign-in (the redirect only reaches a browser on the same Mac). Cancelling the sign-in cancels the task, which stops the listener. Not `ASWebAuthenticationSession` with a custom scheme: with Chrome as the default browser, the redirect that follows the consent page's form POST (Allow) never reaches the app.
4. **Tokens** — access + refresh token in Keychain. Scopes `openid email offline_access`; the `email` and `name` claims of the returned `id_token` are read without checking its signature, for display only, and shown as the account in Settings and onboarding. A `TokenProvider` actor refreshes ahead of expiry, collapses concurrent refreshes into one, retries a request once after `401`, and asks the user to sign in again only when the token endpoint refuses the refresh (a 400 or 401, `invalid_grant` or `invalid_client`). No answer, a 5xx or an unreadable reply keeps the tokens and is retried with the request.

### 5.3 MCP client

Needed calls: `initialize`, `tools/list`, `tools/call`, over Streamable HTTP with the bearer token. `MCPClient` is our own minimal JSON-RPC 2.0 client on `URLSession`, no MCP SDK: it POSTs with `Accept: application/json, text/event-stream`, reads either a JSON or an SSE response, keeps the `Mcp-Session-Id` from `initialize`, and retries once after a `401` with a refreshed token. OAuth is our own code too.

`HiggsfieldMCP` is portable: it builds and is tested on Linux. The Apple-only pieces sit behind protocols with `#if canImport` implementations: `PKCEHasher` (CryptoKit SHA-256) and `AuthorizationPresenter` (loopback listener on Network.framework).

`HiggsfieldAccount` (in `HiggsfieldMCP`) finds the tools by name and validates each tool's `inputSchema` at connect time; `HiggsfieldMCPProvider` maps its calls to the provider protocol. If the Genjutsu tools are missing or their schema changed, the account stays connected but the affected modes are disabled with "Not available for this account", and the user can sign out and use an API key instead.

### 5.4 Risks

- The resource metadata lists "potential clients" for the PKCE flow (Anthropic/Claude clients). An unknown client may be refused, and there is no device code fallback (§5.1); the API key is the way in then.
- Which Genjutsu tools an account gets depends on Higgsfield's MCP catalog. The API-key path does not depend on it.
- Credit prices are not public; the app only shows server estimates and never invents a credit rate.

## 6. Job engine (JobEngine)

```
JobEngine (actor)
 ├─ JobStore (ModelActor)          persists every transition before acting on it
 ├─ Preparer                       MediaKit → PreparedFile (cached by content hash)
 ├─ SlotLimiter (actor)             async semaphore; limit from settings, raised/lowered by API hints;
 │                                    waiters ordered by Run next, then oldest first (saved, survives restart)
 ├─ Runner                         one structured Task per job: upload → submit → poll → download
 ├─ SubmitTracker, StatusBatch,    the actor's bookkeeping, plain structs only it changes: submits in flight (quit),
 │  WriteTurns, NetworkGate          the shared status call's waiters, one writer per job, waits for the connection
 ├─ Downloader                     URLSession download → atomic move into the output folder
 └─ ConnectivityMonitor            NWPathMonitor: pause new network work offline, resume on reconnect
```

- **Idempotency.** Each job gets a UUID idempotency key when it's created; every resubmit reuses it, so a crash between "sent" and "got request_id" can't double-charge.
- **Submits without a key.** The account connection's `generate_video` takes no idempotency key, so it is sent once. A submit that may have reached the server (lost connection, 5xx, or a cancel during the call) throws `outcomeUnknown` and the job fails with "Higgsfield may have started this job"; a user cancel that cuts such a submit off ends the same way, not as `canceled`. A task cancelled before the call sends nothing and stays a plain cancel.
- **Cancel during a submit.** A submit that may have reached the server is never dropped as `canceled`: a retry would send it again under a new key. While a submit with the key is out, or a pause cut one off, cancel is refused (`submitInProgress`). The job resends it with the same key (after a pause, once its connection is back) and can be canceled while queued; a cut-off submit without a key fails as "may have started" instead.
- **One writer at a time.** Every change of a job is saved through `apply`/`save`, which take turns per job, so a change made while the runner works (Run next) can't drop the runner's submit marker.
- **Downloads.** 408, 429, and 403 within 7 days of the result (an expired signed URL, fetched again from the status call) retry with backoff and resume the partial file. 404, 410 and an older 403 fail as expired. The partial file and the result stay in the folder the download started in (`Job.downloadFolder`), even if the output folder changes meanwhile. A result whose missing part won't fit on the disk isn't started, and a write that runs out of space (`NSFileWriteOutOfSpaceError`, `ENOSPC`, `EDQUOT`) while downloading or adding the sound pauses the job with `notEnoughDiskSpace` instead of failing it: the result is paid for, so the partial file and the request stay and Resume continues the download. Before submit, out of space fails the job with a readable reason; nothing is charged yet.
- **Slots.** API returns `400 "Maximum number of concurrent requests (N)"` instead of 429; the runner parses `N`, updates the limiter and puts the job back to `waitingForSlot`.
- **Polling.** Backoff with jitter as Higgsfield's polling guide recommends (2 s, ×1.5, 10 s cap), reset when status changes. `Backoff` lives in `JutsuCore`, so Generate… and character sheets poll on the same schedule (without jitter). Retries of a failed step back off separately (5 s, ×2, 60 s cap). Polling is separate from submission so a slow poll never blocks new jobs. A provider that reads several statuses in one call (`statusBatchLimit`, the account's `jobs_wait`) is polled by one ticker task instead: each polling job waits for the next tick, which asks for every waiting job in groups of up to 12 and hands each job its status, so the per-job state machine is unchanged. The ticker waits as long as the answer's `poll_after_seconds` asks (1–30 s), else with the same backoff; a job the answer leaves out, or any failed or unreadable call, asks its own `status` at once. A cancelled job stops waiting at once.
- **Retries.** A step that fails for a reason waiting can fix (network, 5xx, `modelUnavailable`, concurrency limit, funds after submit) records the streak on the job (`Job.retrying`: failures in a row, since when, next attempt, cause), so its row says "Retrying in 30 s · attempt 4 · last error: …". The next step that gets through clears it, and so does a restart. A job not yet submitted that has failed at least 5 times and for 15 min (`retryPauseFailures`, `retryPauseAfter`) pauses as `keptFailing`, nothing charged, until the user resumes it; a busy account is waited for without a bound. A submitted job is never paused or resubmitted for it: polls that keep failing end at the generation deadline like any other poll, and a download keeps retrying.
- **Deadline.** A job still not finished `generationDeadline` (2 h) after submit fails and is marked `timedOutAt`. Higgsfield may still finish and charge it, so Retry (or "Check again" in the Queue) polls the same request again with a fresh deadline (`checkedAgainAt`) instead of submitting it again.
- **Errors → states.** 401 → connection needs attention, jobs pause; 403 → `paused(insufficientFunds)`; 422 → `failed` with field message; 423/503/5xx/network → retry with backoff (see Retries); `nsfw` → `rejected`. Mapping lives in each provider, the engine only sees typed errors.
- **Quit during a submit.** Quitting gives submits already sent up to 5 seconds to be answered (`JobEngine.stop(finishingSubmitsWithin:)`) and sends no new one meanwhile; the quit confirmation says when a job is being sent. One still cut off is resent with its key on next launch, or, without a key, fails there as cut off and points to the account's history in Library.
- **Resume on launch.** Non-terminal jobs are reloaded: with a `request_id` → poll; prepared but not submitted → submit with the same key; still preparing → prepare again from the cached source. On start the engine also deletes hidden scratch files (`.<id>.partial` and the like) that no active job owns from the output folder and active jobs' download folders, and forgets uploads older than `uploadMaxAge` (1 h).
- **Budget.** `Budget.allows` runs before a job is enqueued; over the cap the UI asks for confirmation (prototype modal). Under a cap, a price not known yet asks too (`SubmitDecision.budgeted`). Create keeps credit estimates by `JobSpec.priceKey` (the spec without its prompt), asks for the missing ones at once, and shows the last known price while a changed form is estimated again. `JobEngine.enqueue` checks again and refuses an over-cap job the user hasn't confirmed (`overCap`); enqueues take turns, so each check counts the job queued before it, and an equal enqueue sent while one is still running (a double click) gets the same job. After upload the engine asks the provider for its price of the exact request; if that price alone takes the day over the cap, the job pauses with `priceAboveCap` and the Queue asks before resuming. A failed quote keeps the preliminary price and is logged.
- **Submit answer.** Its `status` goes through the same mapping as a poll, so a job answered `completed`, `failed`, `nsfw` or `canceled` is handled at once.
- **Operations on a result.** Upscale, Reframe, Remove Background, Dub and Change Voice (`JobSpec.operation`, `Job.parentID` = the result) run the same way as a generation. A result the signed-in account made is named by its job ID, so nothing is prepared or uploaded; if the provider refuses the ID, the file is uploaded and the submit sent once more. The output keeps the result URL's extension and the server's sound, except Remove Background's, which comes without sound and gets the source's back as an MP4 (`PostAction.restoresSourceSound`). Change Voice's list comes from `VoiceLibrary`, read once per connection. Account only, checked against the catalog snapshot (docs/higgsfield-api.md 4.4).
- **Reference images.** Create's References › Generate… makes images through `ImageProvider` (JutsuCore), not `GenerationProvider`: an API key offers a curated list with confirmed schemas (`APIImageModel`), an account `generate_image`. `ReferenceGenerator` (Presentation) holds the form, prices the request (`/estimate`, else the list price as an estimate), submits and polls the runs itself; they never enter the job engine or the Queue. Like `CharacterBuilder.generate` and `VariantScorer.score`, `generate` reads today's spend itself (`SpendStatusReader`) right before it sends anything and, over the cap or with a price not known under one, sends nothing and returns `PaidStart.needsConfirmation`; the sheet asks and calls again with `overCapApproved`. Each request's price is written to `ImageSpendLog` (`image-spend.json`) before its submit, and the request isn't sent when that write fails; it is settled when images arrive and taken off only when the provider answers that the request was refused, failed or was cancelled while queued. Every job the submit answer names goes into `ImageJobLog` (`image-jobs.json`, per owner) and is polled until it ends: a poll that can't be read (401, or any error waiting doesn't fix) leaves the job and its price in place, marks the run interrupted (a 401 also flags the connection), and the job is followed again by `ReferenceGenerator.resume` after the next sign-in, a switch back to that account or a relaunch. `ReferenceGenerator.reset` runs on every connection change: it stops following the old account's runs and drops the upload cache and the price, and an upload or quote that outlives its connection is never kept (a generation counter; `CharacterBuilder` does the same for its uploads). `DailySpend`, the engine's `SpendReader`, Create's cap line, the menu bar and Spending (a "Reference images" line and CSV rows) read it beside the jobs. A picked image is downloaded into `generated/` and added like an opened file, keeping its prompt (`LocalImage.prompt`, also in templates); the rest stay under References for the session.
- **Account elements.** References › From Higgsfield lists the account's uploads and, through `AccountElements` (JutsuCore), its reference elements (`AccountElementsModel`, one list for the connection) and its character sheets. An element's images are downloaded to `account-media/` like an upload's, but keep the media the account listed them as (`LocalImage.serverMedia`), and a job of that account sends the media ID instead of uploading (`GenerationProvider.serverAsset`); a refusal uploads the files and submits once more. Account only, checked against the catalog snapshot (docs/higgsfield-api.md 4.4).
- **Character sheets.** Create Character… makes AI Influencer character sheets through `CharacterSheetMaker` (JutsuCore), not `GenerationProvider`. `CharacterBuilder` (Presentation) holds the form, prices it with the provider's quote of the exact request, and submits that quoted request once: the price is written to `ImageSpendLog` (`purpose` `characterSheets`) before the submit, which isn't sent when that write fails, is taken off when refused or when every sheet fails, and is kept when the answer is lost, which is never resent. Every job ID goes into `CharacterSheetLog` (`character-sheets.json`, per account) first and is polled until it ends, after a relaunch too; a poll that can't be read stops following as Generate…'s do (a 401 also flags the connection) until `resume`. Finished sheets are saved to Library › Images. A write of `ImageSpendLog`, `ImageJobLog` or `CharacterSheetLog` that fails is reported as `LogWriteError` (`saveError`), the records stay in memory, and the Generate… and Create Character sheets say so with Try Again and, for job IDs only this launch knows (`unsavedIDs`), Copy Job IDs. References › From Higgsfield › Characters lists them, and a picked sheet is a `LocalImage` whose `serverMedia` is its job ID, so a job of that account names it instead of uploading. The account's own sheets follow them (docs/higgsfield-api.md 4.4).
- **Virality scores.** Batch comparison's Score Variants… asks the account's Virality Predictor about each variant through `ViralityScoring` (JutsuCore), not `GenerationProvider`: a result the signed-in account made is named by its job ID (`remote.requestID`), so nothing is uploaded; an API key result, another account's or one without a job ID can't be scored and says so. `ViralityPlan` (Presentation) takes the results not scored yet, or all of them again once every one is. The account's scoring is free, so the sheet says "Free" and never asks about the daily cap; a priced provider would show the price for the N videos (or "Price unknown" with explicit agreement) and ask before going past the cap. `HiggsfieldMCPProvider` starts the `virality_predictor` job and polls it with `job_status` until its `params.analysis.scores` arrive. `VariantScorer` scores one result at a time and puts each price into `ImageSpendLog` (`ImageCharge.purpose` `viralityScore`); Spending shows a "Virality scores" line. Scores are kept on the job (`Job.virality`), shown as a 0–100 badge with a small per-frame line; clicking it lists viral potential, hook (0–3 s), engagement, sustain, the peak second, the disclaimer and the dashboard link. Picking the winner stays manual. Account only, hidden with an API key (docs/higgsfield-api.md 4.4).
- **Balance.** `ConnectionStore.refreshBalance` reads `GenerationProvider.balance()` on connect and after each job finishes; `nil` or a failure hides the row, and a sign-out or new sign-in clears it.
- **Background.** Closing the window doesn't quit while jobs run (`applicationShouldTerminateAfterLastWindowClosed` returns false when the queue is busy), nor while work outside the queue runs (`BackgroundPolicy.ImageWork`: Generate… requests and character sheets being sent or followed, and finished images being saved into Library › Images). The quit confirmation counts that work too, and quitting waits, within the same 5 seconds as the queue's submits, for image and character submits already sent (so their job IDs are written down) and for images being saved; image jobs still being made are followed again on next launch. `ProcessInfo.beginActivity` keeps App Nap from freezing polling. A `MenuBarExtra` shows progress; the Dock badge shows the active count; `UserNotifications` reports done/failed/rejected/paused; a draft's "Video ready" offers Render Final… and Show in Finder, a final's Show in Finder, a failed job Retry (`JobNotification.Category`), each running what the same button in the app does. A row of the menu bar panel opens the job in the Queue.

## 7. Media pipeline (MediaKit)

All functions are `async`, cancellable, report `Progress`, and run off the main actor.

| Step | API |
|---|---|
| Probe duration, size, codec, fps | `AVURLAsset.load(.duration, .tracks)`, `formatDescriptions` |
| Trim + transcode to MP4 H.264/AAC | `AVAssetExportSession` with `timeRange`, `outputFileType = .mp4`, `fileLengthLimit` = 200 MiB |
| Re-encode when the limit can't be met by the preset | `AVAssetReader` + `AVAssetWriter` with a target bitrate from duration |
| Upscale for object swap | `AVMutableVideoComposition` with `renderSize` from `upscaled(w, h)` |
| Trim strip thumbnails | `AVAssetImageGenerator.images(for:)` |
| HEIC/TIFF/oversized images → JPEG | ImageIO `CGImageSourceCreateThumbnailAtIndex` with max pixel size |
| Content hash for upload cache | `CryptoKit.SHA256` streamed over the file |
| Source audio back on a silent result | Range cut to AAC (`AVAssetExportPresetAppleM4A`, fade via `AVAudioMix`), then `AVMutableComposition` + passthrough export, so the video is not re-encoded. Decisions in `JutsuCore.AudioPlan`; a failure keeps the silent result |
| Export for editing (Premiere, Resolve, FCP, H.264) | `AVAssetExportSession` with `AVAssetExportPresetAppleProRes422LPCM` (.mov) or `HighestQuality` (.mp4), a video composition whose `frameDuration` is the source's rate for constant frame rate. Presets, take names and the JSON sidecar are pure in `JutsuCore` (`ExportPreset`, `ExportNaming`, `ExportSidecar`) |
| Delivery set export | `DeliveryExporter`: images decoded upright with ImageIO, cropped (`CropFrame.rect`), scaled to the long edge in a `CGContext` of the output color space (alpha only for PNG, else over the background) and written with `CGImageDestination`; videos through `EditingExporter` with an optional crop instruction (`renderSize` = crop). Written aside and moved in; only a file the set wrote before is replaced. Outputs (`DeliveryOutput`, `ImageExportPreset`), file names (`ExportNaming.deliveryBaseName`), the plan (`DeliveryPlan`: all, pending, failed) and the manifest (`ExportSidecar.Delivery`) are pure in `JutsuCore`; `DeliveryRun` (Presentation) runs the files one by one and maps errors to failed or skipped |

Formats AVFoundation can't decode (WebM) fail fast at probe with "convert first".

## 8. Persistence

SwiftData models (in `Persistence`, wrapped by a `ModelActor` so the engine writes off the main thread and views read through `@Query`):

- `JobRecord` — the whole `Job` as JSON (`jobData`; its result is a plain `outputFile` URL, not a bookmark), plus copies of the fields `@Query` filters and sorts on (dates, state, mode, resolution, connection kind, prompt, output path) and the input versions pinned at enqueue. Library metadata is kept in `MaterialRecord`.
- `AssetRecord` — content hash, remote URL and ID, upload date. Reused only within `uploadMaxAge` of the upload.
- `StarredPromptRecord` — a starred prompt, kept when the prompt history is cleared.
- `TemplateRecord` — a `JobTemplate` (Codable): mode, references (or Seedance start and end frames), preset, prompt, resolution, audio, bitrate, Kling orientation and Cinema Studio's creative controls; never a source. Its references point at copies in `templates/<id>/`. An image template (`kind == .image`) holds an image request instead: model, aspect ratio, count, prompt and the image to edit, applied to `ReferenceGenerator`.

`MaterialRecord` is the single Library catalog for images and videos: material identity, versions, origin scoped by provider/account/remote ID/output index, known generation parameters, stars, variant groups and typed multi-input relations. `SwiftDataStore.save` pins input versions on enqueue and registers finished videos in the same transaction as the job state. Image saves and history imports use the same catalog; history refreshes retain downloaded files and edited versions. File-only inputs have no invented generation metadata. Missing files remain in the catalog, and read/write failures are surfaced without replacing damaged records. Culling (unreviewed, kept, rejected) is stored per version (`MaterialVersion.culling`) and the face of a variant group per material (`Material.isVariantPrimary`, set by `makeVariantPrimary`, which finds the group by `MaterialRecord.variantGroupID`); refreshes keep both. The Library builds a `LibraryCatalogIndex` from the decoded materials once per snapshot; hiding rejected results (`LibraryFilter.culled`), folding variant groups (`LibraryVariantGroups`) and the culling Undo stack (`CullingHistory`) are pure, single-pass values in Presentation. Make Video pins each Library image to its catalog version (`LocalImage.material`) and places it in the role picked from those the model declares (`ImageRole`, `CreateForm.makeVideo`); the enqueue records the relation with that role. A result's "Made from" and an image's "Used in" are read by `MaterialRelations` for the one details view open, never per card; a removed or missing source stays, marked unavailable.

`DeliverySetRecord` holds a `DeliverySet` as JSON: `MaterialReference`s to exact versions (never file copies), the outputs, per-item crop frames by aspect, the last result of each item and output, the export folder (with a security-scoped bookmark) and date, a note and a review link. The set freezes on its first exported file; `DeliverySetRecord.update` then refuses other versions or unfreezing, so later edits never change a delivered set (`nextRound` starts a new one). An edit brought back from another app (`OutsideEdit`, working copies in `Edit In/<materialID>_<versionID>_<n>/` next to the store) is copied into the output folder and added by `SwiftDataStore.addEditedVersion` as the material's new current version with a `.parent` input on the exact source version; its prompt and model are kept, its request parameters are not.

`JobRecord` remains the execution and spending ledger, not a second Library. `PendingImageSaves` is a recovery journal for paid outputs awaiting download. The old image index and pre-release schema migration plan have been removed. `StoreContainer` uses the current schema directly; unreleased development stores are not migrated or silently deleted. Move development data aside explicitly when changing its format.

Files:

```
~/Movies/Jutsu Studio/                 the output folder (sandbox entitlement com.apple.security.assets.movies.read-write)
  Videos/                              finished jobs: generations, finals, operations, imports
  Images/                              Generate… images and character sheets (Library › Images)
~/Library/Containers/<bundle>/Data/Library/Application Support/Jutsu Studio/
  default.store                        SwiftData
  create-draft.json                    the Create form between launches, with its files' bookmarks
  sources/                             prepared inputs, cleanable
  cache/presets/                       preset catalog JSON + previews
  cache/model-constraints.json         models_explore limits per account, read again daily; constants without it
  motion-library/, account-media/      inputs downloaded on demand, cleared by "Clear cache"
  pasted/                              images pasted into Create (⌘V), cleared by "Clear cache"
  links/<id>/                          videos and images downloaded from links (Paste URL…, ⌘V), cleared by "Clear cache"
  generated/<id>/                      generated reference images added to Create, cleared by "Clear cache"
  image-jobs.json                      accepted Generate… jobs still being followed, resumed after a relaunch or sign-in
  character-sheets.json                character sheet jobs the app started, per account
  pending-images.json                  paid image outputs awaiting download, including identity and known request inputs
  image-spend.json                     prices of reference image requests and virality scores of the last 31 days, for
                                       the cap and Spending
  templates/<id>/                      copied template reference images, kept by "Clear cache"
```

"Clear cache" keeps the files the Create draft points at (and those of the draft its Undo toast still offers back), so the form never loses an input it shows.

`<bundle>` is `com.jutsustudio.JutsuStudio`, or `com.jutsustudio.JutsuStudio.debug` for a Debug build ("Jutsu Studio Debug"), which therefore has its own store, settings and Keychain item, and downloads to `~/Movies/Jutsu Studio Debug/`. A Debug launch never sees the release build's jobs.

Every kind of result has its own folder inside the output folder, named by `OutputSubfolder` (JutsuCore); a new kind adds a case there. The engine is given the `Videos` folder as its `outputDirectory`, and `ImageLibrary` saves into `Images`. A custom output folder gets the same folders, and its bookmark covers them.

A custom output folder is stored as a security-scoped bookmark. After a switch, the earlier custom folders keep their bookmarks (`OutputFolderHistory`) and their access stays open for the whole launch, so the library can still read the results in them; on launch, a folder that no result or download is in any more is forgotten. Settings (default resolution, cap, notifications) use `@AppStorage`.

## 9. UI (app target)

Scenes:

- `WindowGroup` — `NavigationSplitView`: sidebar (Create, Queue, Library) and detail. Library uses `.inspector` for the details panel. Menu commands: View › Create/Queue/Library (⌘1–⌘3), File › Open… (⌘O, the same path as Open With and Dock drops) and File › Generate (⌘↩, Create's main button, enabled only when it is). The Library menu (Star ⌘L, Render Final…, Delete from Library… ⌘⌫) acts on the open result or the grid's selection, and the Queue menu has Pause All, Resume All, and Cancel Job (⌘.) and Retry (⇧⌘R) for the Queue row selected by a click; each item is enabled only while it applies (`LibraryMenuTargets`, `QueueJobCommands`), and the screens publish their actions to the menus as `FocusedValues`. These, gallery search (⌘F) and Library's history refresh (⌘R) are the defaults of Settings › Shortcuts (`ShortcutAction`), read through `@StoredShortcut`. ⌘V in Create adds a copied video or images like opened files, a copied image (a screenshot) as a reference saved to `pasted/`, and a copied `https:` link like Paste URL… in the Source and References sections: `MediaLinkDownloader` downloads it to `links/` with progress and Cancel, refusing pages and other non-media by `Content-Type` (`MediaLink.classify`), and the file then goes where a dropped one would, remembering its link (`SourceClip.remoteOrigin`, `LocalImage.remoteOrigin`). A job that sends such a file as downloaded (whole, untrimmed, not upscaled, MP4 or JPEG/PNG/WebP/GIF: `linkableOrigin`) asks the provider for `linkedAsset` before uploading: an API key sends the link itself, up to 200 MiB; the account uploads as usual until `media_import_url` is verified. A link the provider refuses at submit is uploaded instead, once; ⌘A, ⌘V and ⌘⌫ go to the text being edited first (`TextAwareShortcut`).
- Settings — a page of the main window (sidebar, account plate, ⌘,), not a window of its own, with Connection, General, Output, Storage, Spending (breakdown, CSV export and the daily cap: USD for an API key, credits for an account; only while connected), Notifications, Agents (§12) and Shortcuts tabs, drawn with the app's own tab switcher and themed rows. Before a connection exists, ⌘, shows it over the onboarding with a back button.
- `MenuBarExtra` — compact queue and today's spend.

Composition root: `AppEnvironment` (`@Observable`, `@MainActor`), created once in `JutsuStudioApp`. It owns the `ModelContainer`, `JobEngine` (SwiftData store, `MediaPreparer`, `NWPathMonitor` connectivity) and `ConnectionStore`, and on every connection change builds the provider (`HiggsfieldAPIProvider`, or `HiggsfieldMCPProvider` with a `TokenProvider` that writes refreshed tokens back to Keychain) and hands it to `engine.setProvider`. Its extensions are wiring: the rules of Delete from Library, stars and likes, templates and Save to Higgsfield… live in Presentation (`LibraryDeletion`, `LibraryStarring`, `TemplateLibrary`, `CharacterSaving`) behind small ports (`LibraryRecords`, `LibraryTrash`, `LibraryStarStore`, `TemplateRecords`, `TemplateImages`) that the app implements with SwiftData and `FileLayout`, and the provider's optional services (`MotionLibrary`, `GenerationLikes`…) are cast in one place, `AppEnvironment+Capabilities`. Views read it with `@Environment(AppEnvironment.self)` and `@Environment(ConnectionStore.self)`.

State: one `NavigationModel` (`@Observable`, `@MainActor`) for navigation and the Create drafts, one per side of Create (the video `CreateForm` and the Image side's `ImageDraft`, a snapshot of `ReferenceGenerator`'s form) with the side in front, which it saves a second after each change and on quit (`CreateDraftStore`) and restores on launch without the files that can no longer be read. Edit inputs, a template, a prompt from history or a new source replace the draft through `replaceDraft`; when that loses inputs the user had edited (`CreateForm.dropsInputs`), the toast offers them back with Undo (`DraftReplacement`). `ConnectionStore` holds the connection; lists come from `@Query`. The Queue's "Didn't finish" section reads failed, rejected and canceled jobs from the store (`JobRecord.problemsNewestFirst`), so newer results never push them out of reach; its Remove and Clear all only hide them (`QueueProblems`, kept in `UserDefaults`), and the records stay. Logic a view needs (validation, messages, mode availability) lives in `Presentation` as plain values and functions with tests; the app target keeps only SwiftUI. Views are grouped by feature: `Onboarding/`, `Create/` (form, stage with `AVPlayerView`, trim strip), `Queue/`, `Library/`, `Settings/`, `Templates/`, plus `Connection/` (sign-in plumbing), `System/` (menu bar, notifications, Dock integration), `DesignSystem/` (theme, shared controls) and `About/`.

First launch with no account shows Onboarding with the two cards: "Connect your Higgsfield account" and "Use an API key".

## 10. Security and privacy

- App Sandbox: `network.client`, `network.server` (the OAuth loopback redirect on 127.0.0.1), `files.user-selected.read-write`, `files.bookmarks.app-scope` (custom output folder), `assets.movies.read-write`, and the app group `<team>.com.jutsustudio.jutsustudio` (`.debug` for Debug) whose container holds the agent socket (§12). Hardened Runtime. No other entitlements.
- `os.Logger` everywhere; tokens, keys and signed URLs logged with `privacy: .private` so they are redacted in Console.
- No telemetry, no backend. Only hosts contacted: `api.higgsfield.ai`, `mcp.higgsfield.ai`, the OAuth servers it advertises, and the storage hosts of presigned URLs.

## 11. Testing and CI

- `JutsuCore`: pricing, budget, validation, every state transition.
- `HiggsfieldKit` (`HiggsfieldAPI` / `HiggsfieldMCP`): requests and error mapping against a `URLProtocol` stub with recorded responses; the MCP tool contract; OAuth discovery, PKCE and refresh single-flight.
- `HiggsfieldProviders`: job specs to requests, client errors to `ProviderError`, account model params and prices.
- `MediaKit`: small fixture clips (HEVC MOV, 720×480 MP4, 35 s clip) — trim length, output codec, upscale size, size limit.
- `JobEngine`: fake provider + in-memory store — slot limits, 400-concurrency requeue, resume after "crash", idempotency key reuse.
- CI: GitHub Actions. Lint and the Linux tests of the portable modules, then on a macOS runner the package tests of every module and an app build. No real API calls and no secrets in CI.
- `JutsuAgent`: the wire format, the listener on real sockets in `/tmp` (long paths, mode 0600, Allow agents read per command, uploads that never overwrite). `JutsuMCP`: the JSON-RPC exchange for every protocol version, tool schemas and argument checks, and finding and starting the app against a fake launcher, so no test starts anything.

## 12. Agents

AI agents on the same Mac (Claude Code and other MCP clients) drive the app through `jutsu`, a command-line helper bundled at `Contents/Helpers/jutsu` and signed with the app. `claude mcp add jutsu -- "<app>/Contents/Helpers/jutsu" mcp` adds it; Settings › Agents shows that line for the copy of the app it is in.

- **Helper.** `jutsu mcp` is an MCP server on stdin and stdout, one JSON-RPC message per line, written for the protocol without an SDK (`JutsuMCP.MCPServer`). It serves the stateless 2026-07-28 revision (`server/discover`, the version and client capabilities in each request's `_meta`, `resultType`, `-32022` for a version it doesn't speak) and the `initialize` handshake of 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05. Tools have annotations and an output schema; a result carries `structuredContent` and the same JSON as text. A tool's own failure is a result with `isError` and `{code, message, retryable, next}`; a malformed call is a JSON-RPC error. Each request is answered in a task of its own (`JutsuMCP.MCPConnection`), so a call waiting on the app (`jobs` with `wait_seconds`) doesn't hold up the ones after it; `initialize` and notifications are handled in turn, each reply is written as one whole line, and `notifications/cancelled` cancels its request, which then gets no reply. Socket round trips block a Dispatch thread, not one of the shared task threads, and stdin is read on a thread of its own so the main thread stays free for Launch Services. Logs go to stderr. It is not sandboxed: it finds the app three folders up from itself, reads the app group from the app's Info.plist (`JutsuAppGroup`), and, when the socket doesn't answer, starts the app in the background through Launch Services and waits up to 10 s for it. A build without a team (ad hoc) has no group and the helper says so. `JUTSU_AGENT_SOCKET` points it at another socket for development and never starts anything.
- **Socket.** `agent.sock` in the app group's container, mode 0600, listened on from launch by `AgentServer` (POSIX sockets, so the long container path fits). One JSON object per line with a protocol version; an upload's bytes follow its line. Allow agents (Settings › Agents, off by default) is read from the saved preferences for every command, never from launch arguments, so turning it off refuses the next command with `agents_off` and stops nothing already running. Both sides check every argument. No call blocks for long: a command's answer waits at most 55 s for its work (`AgentProtocol.answerDeadline`), then answers `still_working` (retryable; the work goes on, and the same request or `jobs` picks it up), and the helper's socket timeout is 60 s (`AgentProtocol.helperTimeout`).
- **Inbox.** An uploaded file goes into a folder of its own in `inbox/` next to the socket and is moved into place without replacing anything. `AgentServer.UploadGate` runs before any byte is read: only `create_video` and `create_image` take files, and the request ID is looked up there, so a `request_conflict` (the same ID with other parameters) or a request already taken refuses the upload before it starts. So does a lack of room (`AgentInbox.roomProblem`, `file_refused`, not retryable): an upload must leave about 2 GB free on the volume, and the inbox holds at most 8 GiB, each file at most 4 GiB. At launch the app removes uploads older than a day that no job and no open image request reads (refused requests, and jobs gone or finished over a week ago); it never touches the agent's own files. A `retry` whose job reads an upload that was removed is refused with a pointer to a new `request_id`.
- **Tools.** In `tools/list` order: `capabilities`, `quote`, `create_video`, `jobs`, `job_action`, `create_image`, `library_search`, `library_mark`, `enhance`, `delivery_set`, `export`, `show` (`Tool`, matching the groups `capabilities` lists). Each parser in `Tools.swift` and `Tools+Library.swift` checks its arguments strictly, and the app checks the decoded command again (`AgentFields.problem`).
  - `capabilities`: the connection (none, API key or account, with the plan and credits when known), the daily agent budget in whole cents or credits with what was spent, what is reserved by jobs in flight and what remains, whether agents may use unlimited generations (`unlimitedAllowed`), and the tools on offer. With `models`, the video models, or one, with whether the connection runs it, whether it has drafts, makes clips without a source or needs a prompt, and, per mode, its length window, image counts and whether it needs a style or a source, from what Create last read rather than a network call. `image_models`, `styles` and `voices` add the image models `create_image` takes, Restyle's cached styles and Change Voice's voices, also without a network call.
  - `quote`: what a request would cost, with the files counted rather than read, and the budget left today, and `paysUnlimited` when the plan's unlimited allowance would pay for it as the person's Use unlimited generations and the account's allowance stand (`CreateContext.paysUnlimited`; then the price is 0 and the blocker says whether agents may use it). Read-only.
  - `create_video`: queues a job from the agent's own files with a `request_id` of its own and a `max_cost` (dollars, kept as whole cents rounded down, or credits). The request becomes the same `JobSpec` the Create form builds (`AgentVideoOrder`): a copy of the person's defaults with the request's fields set on it, never the visible Create form. Where the form would fit a request (move a range into the model's window, drop references over the limit), the agent's request is refused with the reason instead. The same ID with the same parameters (a SHA-256 fingerprint over the parameters, file paths and sizes, and `max_cost`) returns the job it made, also after a relaunch (`agent-requests.json`, 30 days); with other parameters it is `request_conflict`. It is `idempotentHint: true`. A `style` must be one of the cached style catalog (`PresetCatalog.agentStyleRefusal`).
  - `jobs`: the one place all the agent's work is followed: its jobs, image requests and exports, by ID or the latest (newest first, paged with `nextCursor` → `cursor`, `AgentJobPage`). Each item has a `kind` (a video mode, `image`, `export` or `delivery_export`), its state, progress, price, the hold and whether a person must act, and for an export its folder, the per-file results and the written paths. `wait_seconds` (at most 50) waits until each is settled (done, failed, paused, cancelled, unknown) or the time is up; a timeout reports `timedOut` and stops nothing. An ID the app doesn't know answers state `unknown` with a next step rather than an error (`AgentJob.unknown`).
  - `job_action`: `cancel`, `retry` and `run_next` on the agent's own jobs, and `pause_queue` and `resume_queue` for the agents' jobs not yet sent (`JobEngine.pauseAll(agentsOnly:)`): they never touch the person's own jobs, and `resume_queue` lifts only a pause an agent made (`AgentOrigin.pausedByAgent`), never the person's own Pause all, which takes over the jobs an agent paused. It never resumes a job held by its spending limits, retries a job that may have been charged, or deletes anything.
  - `create_image`: images made exactly as the Image side of Create makes them (`AgentImageOrder` against `ReferenceGenerator.models`, never the visible form), with a `request_id`, the same fingerprint log and a `max_cost`. They are sent through Generate…'s own runs; see the image guard below. `results` lists the saved images' paths in Library › Images.
  - `library_search`: read-only. The Library's own rows (`MaterialLibrary.row`, `LibraryFilter`) of results with a file on this Mac, filtered by text, kind, star, verdict, model, mode and date, newest first with a cursor (`AgentLibrarySearch`). Rejected results are left out unless asked for; prompts are cut to 200 characters.
  - `library_mark`: the culling verdict (keep, reject, clear) and the star, set apart, through the Library's own paths (`CullingHistory.apply`, the star and its Higgsfield like). Marking the same way again changes nothing; nothing is deleted.
  - `enhance`: an Enhance operation queued as the Library's Enhance sheet queues it (`AgentEnhanceOrder`, `EnhanceAvailability`, `Job.operationSpec`), as a child of the result, with the agent's origin, `request_id` and `max_cost`, so the engine's spending guard checks it like any agent job. A Topaz upscale is refused with `priced_after_run`, as its price is known only after the run.
  - `delivery_set`: `create`, `list` and `export` of Library › Delivery Sets. Export writes through the sheet's own `DeliveryExportModel` into a folder the person exported a set to, else the output folder's `Exports`, with per file `done`, `failed` or `skipped`. A name that is taken gets a new one (`AgentExports.deliveryTasks`): it never writes over a file, even the set's own. Export starts the work and answers with its handle (kind `delivery_export`), like `export`.
  - `export`: Export for Editing presets (`EditingExportModel.write`) with an optional JSON sidecar, into the output folder's `Exports`, under names no file has. It starts the work in the app (`AgentOperations`) and answers at once, or after `wait_seconds` (at most 50), with a stable operation ID, its state and the files done so far; `jobs` follows it from there. A wait that times out cancels nothing, and the export goes on when the agent disconnects. Exports are kept in memory only, finished ones for a day: a relaunch forgets running exports' handles, and `jobs` then answers `unknown` with a pointer to the folder and to exporting again.
  - `show`: opens Create, Queue, Library or Settings, or a job (its result in Library when done, else its Queue row), and brings the window forward.
- **Origin.** An agent's job carries `Job.agent` (`AgentOrigin`): the client's name, the request ID, the allowed `max_cost`, its reservation, and a hold when stopped. The Queue row says "Agent · <client>" and what it was allowed to spend.
- **Spending guard.** The engine, not the app, keeps an agent's job within its limits. In `JobEngine.submit` after the slot and the cancellation check, and before the submit marker is saved, `clearAgentSpend` (`JobEngine+AgentGuard.swift`) first applies the person's own daily cap (`.priceAboveCap`), then `AgentSpendDecision.decide`: the price must be known (a server quote or an exact price), at most `max_cost`, and fit the remaining daily agent budget, where in-flight reservations count. A job the plan's unlimited allowance pays for (`JobSpec.usesUnlimited`) skips the cap and the budget, which don't count it, and goes out only when Settings › Agents › Let agents use unlimited generations (`AgentPreferences.allowsUnlimited`, off by default, read through `AgentSpendPolicy.allowsUnlimited` for every submit) is on; it reserves 0 with no limit (`AgentSpend.paysUnlimited`), and a charge the answer reports replaces that (the job's price when the answer says the allowance didn't pay but not how much). Off, it is held as `.unlimitedNotAllowed`. Once such a submit settles above 0, the ledger's day reports `AgentSpendTotal.unlimitedCharged`, and until the day ends agents' jobs for the allowance are checked like any other (cap, `max_cost`, budget), so with no budget they are held; `capabilities` then reports `unlimitedAllowed` false. A job that fails any of these, or whose ledger can't be read, pauses as `.paused(.agentLimit)` with its `AgentHold`; only the person's Confirm in the Queue sends it, which approves that price (`Job.approvedPrice`, `AgentImageRecord.approvedPrice`), and no agent action resumes it. A price that is higher when it is checked again (a quote that came only after the Confirm) holds it again as `.aboveApprovedPrice`. Otherwise the price is reserved in the ledger before anything is sent, and the reservation is saved with the submit marker (`beginSubmit`).
- **Agent ledger.** `AgentSpendFile` (`agent-spend.json` in the app's data folder, apart from the job store and the person's cap) holds whole cents or credits, never floating point: prices round up, sums saturate, and parsing clamps. Reading is strict, so a damaged file holds every agent job rather than forgetting what was spent. A reservation is released only when the request was certainly not sent (stopped before the send, or refused by a `ProviderError` that `mayHaveBeenTaken` says the server didn't take); on `outcomeUnknown` and on a cancel after the send it stays. A job that lets go of a reservation it still holds (a retry, which is a new attempt, or a new submit after one that may have been taken) settles it at the amount reserved first (`keepAgentSpend`), so neither the retry nor the next launch gives back what that submit may have been charged. The charge the server reports replaces it (`settleAgentSpend`). Higgsfield doesn't bill a generation that failed, was refused by moderation or was cancelled, so once the provider reports one of those (a poll's `failed`, `rejected` or `canceled`, or the person's cancel of a job still queued there), `unbillAgentSpend` marks the job as an unbilled part of its submit's entry (`AgentSpendLedger.unbill`): a variant is one share of its sender's entry (`AgentOrigin.paidBy`, `paidParts`), and the entry counts only its billed parts' share, rounded up (`AgentSpend.counted`). A job whose outcome isn't known (cut off, past the deadline, unanswered) keeps counting. It keeps the last two days. At launch `JobEngine.reconcileAgentReservations` releases a reservation whose job never saved it with a submit marker (the app stopped in between, so nothing was sent); one held by its job, by a job with a submit marker, or by an image request stays.
- **Image guard.** `AgentImageQueue` (`agent-images.json`, read strictly, 30 days) records each `create_image` request before anything runs, then hands it to `ReferenceGenerator.submit` with an `AgentImageSubmit` hook. Once the request is built and its input uploaded, and before the person's image spend is written and it is sent, the hook reads the provider's quote (else the model's list price, an estimate), applies the person's daily cap strictly (`Budget.allows`) and `AgentSpendDecision.decide` (with `paysUnlimited: false`: image requests are always sent with `use_unlim` false, so the unlimited setting never applies to them), reserves the price in the same ledger and saves the record as possibly sent. An unknown price, a price over any limit, or a ledger that can't be written holds the request in the Queue's image requests with the reason; only the person's Send there sends it, at the price shown. A reservation is released only when the submit stopped before it went out or the provider refused it; an accepted submit settles it at the reserved amount, and once every job of the request has ended, the jobs that failed, were refused or were cancelled (`ImageJobRecord.isUnbilled`, a cancel marks each job it cancelled) are unbilled parts of it, so it counts the share of the jobs that made images. While any job is still pending (following stopped, or the provider refused a cancel) the full reservation stays. At launch `restore` releases reservations the queue never saved, fails a request that was being sent and whose answer was lost (its reservation stays), and shows held requests again. The rows show the agent and its `max_cost`.
