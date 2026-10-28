# Higgsfield API reference

How Jutsu Studio talks to Higgsfield: the REST API used with an API key, and the MCP server used with a Higgsfield account. Each section covers the contract the app relies on, what the public documentation says, and what the app doesn't use yet.

- **Last reviewed:** 2026-10-28
- **Code:** `Packages/HiggsfieldKit` (`HiggsfieldAPI`, `HiggsfieldMCP`, `HiggsfieldCore`) and `Packages/JutsuKit/Sources/HiggsfieldProviders`
- **Audience:** contributors changing the providers, adding models, or debugging a failed request

## Contents

1. [Connections at a glance](#1-connections-at-a-glance)
2. [Sources and verification](#2-sources-and-verification)
3. [REST API](#3-rest-api)
4. [MCP server](#4-mcp-server)
5. [REST and MCP differences](#5-rest-and-mcp-differences)
6. [Open questions](#6-open-questions)
7. [Changelog](#7-changelog)
- [Appendix A. REST model catalog](#appendix-a-rest-model-catalog)
- [Appendix B. MCP tools Jutsu doesn't use](#appendix-b-mcp-tools-jutsu-doesnt-use)

---

## 1. Connections at a glance

| | API key (REST) | Higgsfield account (MCP) |
|---|---|---|
| Endpoint | `https://api.higgsfield.ai` | `https://mcp.higgsfield.ai/mcp` |
| Auth | `Authorization: Key <id>:<secret>` | OAuth 2.1 bearer token (PKCE, loopback redirect) |
| Billing | Prepaid credits, quoted in USD by `/estimate` | Plan credits, quoted with `get_cost: true` |
| Protocol | JSON over HTTPS, one endpoint per model | JSON-RPC 2.0 over Streamable HTTP (SSE) |
| Models in Jutsu today | Genjutsu (Motion Transfer, Restyle, Object Swap), Seedance 2.5, Kling 3.0 and 2.6 Motion Control, Kling O3 video reference and Edit, Wan 3.0, 3.0 Prime and 2.7 reference, Cinema Studio 4.0, MiniMax H3 reference (`models.json`) | Genjutsu, Genjutsu Lite, Seedance 2.5, Kling 3.0 Motion Control, Kling O3 Edit, Wan 3.0 and 3.0 Prime reference, Cinema Studio 4.0, MiniMax H3 and H3 Max, Genjutsu Styles |
| Account data | None (no balance or history endpoint) | Balance, history, likes, transactions, uploads, galleries |
| Swift entry points | `HiggsfieldAPIClient`, `HiggsfieldAPIProvider` | `MCPClient`, `HiggsfieldAccount`, `HiggsfieldMCPProvider` |

Both providers conform to `GenerationProvider` (`Packages/JutsuKit/Sources/JutsuCore/Provider/GenerationProvider.swift`). `ProviderKind.apiKey` is REST, and `.account` is MCP.

## 2. Sources and verification

Each fact in this document comes from one of three kinds of source:

| Level | Meaning |
|---|---|
| **Verified** | The app calls it, and it was checked against the live service on the review date. |
| **Documented** | Stated in Higgsfield's public docs, but the app doesn't call it yet. |
| **Unverified** | Taken from official tooling or third-party MCP directories, not from Higgsfield's API docs or a live call. Confirm before relying on it (issue #37). |

Public sources:

| Source | URL | Notes |
|---|---|---|
| API docs index | `https://docs.higgsfield.ai/docs/llms.txt` | Every page has a Markdown twin: append `.md` to its path. |
| Model catalog | `https://docs.higgsfield.ai/docs/models.md` | 84 endpoints (17 image, 67 video) with JSON Schemas per page. |
| OpenAPI | `https://docs.higgsfield.ai/docs/openapi.json` | v2.0.0. Covers status, cancel, delete (`DELETE /requests/{request_id}`, added 2026-10-24) and a few legacy models only (9 paths). |
| Price catalog | `https://dash.higgsfield.ai/api/v2/catalog-models/?output_type=video` (or `image`) | Public JSON, list prices. |
| Pricing page | `https://open.higgsfield.ai/pricing`, from `https://dash.higgsfield.ai/api/v2/pricing/models/?page_size=50` | Public JSON: per endpoint, `original_amount` (list) and `amount` (discounted) per second for each `configuration` (resolution, length), with a "from" or "exact" `qualifier`. |
| Website index | `https://higgsfield.ai/llms.txt` | Product surface, not the API. |
| MCP metadata | `https://mcp.higgsfield.ai/.well-known/oauth-protected-resource/mcp` | Public, see [4.2](#42-authorization). |
| Official CLI | `https://github.com/higgsfield-ai/cli` (`MODELS.md`) | MCP-backed; lists model IDs. |
| Official skills / plugins | `https://github.com/higgsfield-ai/skills`, Cursor plugin `commands/higgs.md` | List MCP tool names. |
| SDKs | Python `higgsfield-client`, Node `@higgsfield/client` | REST only. |

The MCP tool catalog (`tools/list`) needs a signed-in account, so it isn't public. Tools the app doesn't call are listed from the official plugin and from third-party directories, which are incomplete: none of them list `get_presets`, `set_generation_like` or `assets_picker_list`, which the app uses.

---

## 3. REST API

### 3.1 Base URL and authentication

```http
POST https://api.higgsfield.ai/<model-endpoint-id>
Authorization: Key <KEY_ID>:<KEY_SECRET>
Content-Type: application/json
Accept: application/json
```

- Credentials come from <https://console.higgsfield.ai>. The legacy `hf-api-key` / `hf-secret` headers still work; Jutsu sends only `Authorization`.
- `api.higgsfield.ai` is the only API host. The older `platform.higgsfield.ai` is retired by 2026-10-31 (notice on `status.higgsfield.ai`, 2026-10-28); Jutsu doesn't use it.
- A bad or missing key returns `401 {"detail": "Invalid credentials"}`.
- A key can be given an expiry date or disabled in the Console (`docs/enterprise/access-control`). Such a key returns `403` with a code next to `detail`: `{"code": "api_key_expired", "detail": "This API key has expired.", "expires_at": "2026-09-21T12:00:00Z"}`, or `"code": "api_key_disabled"`. Jutsu maps both codes, next to `detail` or inside a `detail` object, to `.unauthorized`, like a 401: the connection needs attention and `validateKey` reports the key as refused. Any other 403 is the balance (3.10).
- A model the account can't use returns `404`, `423` or `503`, depending on the model's state.
- Jutsu sends the key only to the API host. Status and cancel URLs returned by the server are used only when they are HTTPS on the same host and port; otherwise the documented path is used (`HiggsfieldAPIClient.trustedURL`).
- Onboarding validates a key with the free `GET /models/higgsfield/genjutsu/restyle/v1.0/presets` (`validateKey`).

### 3.2 Request lifecycle

Generation is asynchronous: submit, then poll (or receive a webhook).

| Status | Terminal | Meaning | Jutsu `GenerationStatus` |
|---|---|---|---|
| `queued` | no | Waiting; can still be canceled | `.queued` |
| `in_progress` | no | Running; can't be canceled | `.inProgress` |
| `completed` | yes | Output URLs present | `.completed(videoURL:)`, or `.failed` if no URL |
| `failed` | yes | `error` may explain | `.failed(message:)` |
| `nsfw` | yes | Rejected by moderation | `.rejected(.explicitContent)` |
| `canceled` | yes | Canceled while queued | `.canceled` |
| anything else | — | Treated as a new intermediate state | `.inProgress` |

Mapping: `StatusResponse.generationStatus` in `Packages/HiggsfieldKit/Sources/HiggsfieldAPI/WireTypes.swift`.

### 3.3 Submit

```http
POST /higgsfield/genjutsu/motion-transfer/v1.0
Idempotency-Key: 6f1c9a52-0d7e-4c0e-9a1b-2f3d4e5f6a7b
```

```json
{
  "image_urls": ["https://…/ref.png"],
  "prompt": "",
  "resolution": "720p",
  "video_url": "https://…/source.mp4"
}
```

Response (`200`):

```json
{
  "status": "queued",
  "request_id": "d7e6c0f3-6699-4f6c-bb45-2ad7fd9158ff",
  "status_url": "https://api.higgsfield.ai/requests/d7e6c0f3-…/status",
  "cancel_url": "https://api.higgsfield.ai/requests/d7e6c0f3-…/cancel"
}
```

- Store `request_id` immediately. It identifies the request for polling, cancel, webhook deduplication and support.
- Every response carries `X-Correlation-ID`. Jutsu keeps it with the job (`SubmittedRequest.correlationID`) for support requests.
- The API rejects `null`. Send `""` or `[]`, or omit optional fields. Jutsu always sends `prompt` and `image_urls`, and omits `preset_id` outside Restyle, whose schema forbids extra keys.
- Webhooks: append `?hf_webhook=<url-encoded https URL>`. Jutsu has no server, so it doesn't use them ([3.9](#39-webhooks)).

### 3.4 Idempotency

- `Idempotency-Key` is accepted on generation submits only: 1–255 visible ASCII characters, no whitespace. UUIDs are recommended.
- Retrying with the same key, endpoint, body and webhook returns the original `request_id` and doesn't charge again. The replay may say `queued` even when the request has finished, so read `status_url`.
- Same key, different body: `422 {"detail": "Idempotency-Key was already used with different request parameters"}`. Don't fix this by generating a new key automatically.
- Requests rejected before acceptance (401, validation) don't use up the key.
- Field order doesn't matter. Array order, omitted fields, explicit `null` and different URLs do.
- Jutsu makes one key per job, sends it lowercased, and reuses it on every retry of that submit (`HiggsfieldAPIClient.submit`, `GenerationProvider.submitIsIdempotent`).

### 3.5 Polling

```http
GET /requests/{request_id}/status
```

Completed video:

```json
{ "status": "completed", "request_id": "…", "video": { "url": "https://…/video.mp4" } }
```

Image models return `images: [{url}]`, and audio models `audio: {url}` and `audios: [{url}]`. Some video and 3D operations add `zip`, `mov`, `jsx`, `fbx` or `ply` artifacts.

Recommended: start at 2 s, back off ×1.5 to 10 s, add jitter. Keep polling on 5xx or network errors; stop on 401 and 404.

### 3.6 Cancel

```http
POST /requests/{request_id}/cancel
```

- `202 Accepted` with an empty body while every job in the request is still `queued`. A canceled request is refunded.
- `400` once processing has started. Jutsu maps it to `HiggsfieldError.validation`.

### 3.7 File uploads

1. Ask for a presigned URL:

   ```http
   POST /files/generate-upload-url
   {"content_type": "video/mp4"}
   ```

   ```json
   {
     "public_url": "https://cdn…/input/….mp4",
     "upload_url": "https://storage…/presigned",
     "content_type": "video/mp4",
     "upload_headers": { "Content-Type": "video/mp4", "x-amz-tagging": "retention=temporary" }
   }
   ```

2. `PUT` the bytes to `upload_url` with **every** header in `upload_headers`, and without the API key. The URL expires after one hour.
3. Pass `public_url` as the model's `video_url`, `image_url(s)` or `audio_url(s)`.

- Supported types: `image/jpeg`, `image/jpg`, `image/png`, `image/webp`, `image/gif`, `audio/wav`, `audio/x-wav` and `video/mp4`. The PUT content type must match the requested one.
- Any public HTTPS URL works as input, so a file that is already online needs no upload. Jutsu sends the link of a file downloaded from a pasted link when the job uses it whole and as downloaded (`HiggsfieldAPIProvider.linkedAsset`, issue #47); a validation error for it makes the job upload the file instead. On the account the same file is imported with `media_import_url` (4.4, issue #90).
- Jutsu refuses an `upload_url` that isn't HTTPS. A storage error on PUT maps to `.server`, not to a key or balance problem.

### 3.8 Estimate

```http
POST /estimate/{model-endpoint-id}
```

The body is the same as the submit body; nothing is charged.

```json
{ "credits": "1.500", "usd": "0.094" }
```

Both amounts are decimal strings, and `credits` may be absent. Jutsu reads `usd` (`EstimateResponse`). The billing page (`https://docs.higgsfield.ai/docs/concepts/billing-and-retention`, "Estimate a request", read 2026-10-15) calls the answer authoritative for the account; its only example is Soul, and the OpenAPI file has no `/estimate` path. It is the only price endpoint: there is no dry-run flag on submit, and the SDKs and the CLI have no REST estimate.

- **Before upload (issue #113).** A job with nothing to upload (Seedance from a prompt) has its whole body before anything happens, so Create asks `/estimate` with that body as the form changes, debounced, and shows it as **Price from Higgsfield** (`HiggsfieldAPIProvider.quoteBeforeUpload`). Jobs that differ only in the prompt share the quote, kept for the connection (`QuoteCache`); a failed quote isn't kept, and the list price stands. A job without a prompt isn't asked (the request needs one).
- **After upload.** Every other job needs its uploaded URLs in the body, so before upload the app shows the list price from `Packages/JutsuKit/Sources/JutsuCore/Resources/pricing.json`, and right before submit `serverEstimate` replaces it with the exact quote, which the daily cap checks again.
- A body without the media would be a different request, which the docs don't say is priced the same, so a job with a source or images is never quoted before upload.

### 3.9 Webhooks

Not used by Jutsu; documented here for completeness.

- Pass `?hf_webhook=` on submit. Higgsfield `POST`s `{request_id, status, error, payload}` after `completed`, `failed` or `nsfw`; once a request finishes the payload also has `expires_at` (3.12).
- The endpoint must answer `2xx` within 10 s. 5xx and network failures are retried for up to 2 hours; 4xx responses are permanent. The URL must be HTTPS, resolve only to public addresses and carry no credentials.
- Deliveries can repeat: deduplicate by `webhook-id`, or by `request_id` + `status`.
- **Signing (since 2026-10-24).** Deliveries are signed with the [Standard Webhooks](https://www.standardwebhooks.com/) scheme: `webhook-id` (stable across redeliveries), `webhook-timestamp` (Unix seconds; reject outside five minutes) and `webhook-signature` (one or more space-separated `v1,<base64>` signatures of the raw body). The secret belongs to the account, starts with `whsec_`, and is revealed or rotated in the Console's **Settings**; deliveries are signed from the moment it is first revealed. After a rotation the previous secret works for 24 hours and each delivery carries one signature per secret. The older `X-Webhook-Secret-Key` header is still sent for integrations that passed a secret, and will be retired.
- No delivery is made for a request whose data was deleted (3.12).

### 3.10 Errors

Most errors use the FastAPI envelope: `{"detail": "text"}` or `{"detail": [{"loc": [...], "msg": "..."}]}`. Some carry a machine-readable `code`: inside a `detail` object (`{"detail": {"code", "message", "retryable", …}}`, a full queue or a queue admission outage) or next to `detail` (an expired or disabled key). Jutsu reads the code from either place and takes a `detail` object's `message` as the text. The docs ask not to parse the human-readable messages for decisions, so Jutsu decides by status and code only.

| Status | Meaning | Retry | Jutsu `HiggsfieldError` |
|---|---|---|---|
| 400 | Invalid parameters or rejected input | After fixing | `.validation(field:message:)` |
| 401 | Missing or invalid key | No | `.unauthorized` |
| 403 | Not enough credits | After topping up | `.insufficientFunds` |
| 403 with `code` `api_key_expired` or `api_key_disabled` | The key expired or was disabled (3.1) | With another key | `.unauthorized` |
| 404 | Request or model not found for this account | No | `.validation` |
| 409 | The request is still running, as for a delete of a `queued` or `in_progress` request (3.12; not called) | After it finishes | `.server(status:)` |
| 422 | Validation failed, idempotency key reused with a different body, or `Hf-Expires-After` out of range | No | `.validation` (field from `loc`, without `body`/`query`/…) |
| 423 | Model temporarily blocked | Later | `.modelUnavailable` |
| 429 | The account's generation queue is full (`account_queue_full`), or an endpoint's own limit (3.11) | After `Retry-After` | `.concurrencyLimit(retryAfter:)` |
| 500 | Server error | Yes, with backoff | `.server(status:)` |
| 503 with `code` `admission_control_unavailable` | Queue admission is briefly unavailable (`retryable: true`) | Yes, with backoff | `.server(status:)` |
| 503 | Model disabled or not ready | Later | `.modelUnavailable` |

Mapping: `Packages/HiggsfieldKit/Sources/HiggsfieldAPI/HiggsfieldAPIErrors.swift`. Failed and `nsfw` requests aren't charged; reserved credits are refunded.

### 3.11 Rate limits

Status: **Documented** (`docs/concepts/rate-limits`, 2026-10-24); a full queue hasn't been seen live.

- The main limit is concurrency: how many requests may be processing at once, per account and sometimes per model. The values are in the Console. Successful answers carry no rate-limit headers.
- **Above the concurrency limit a generation request is queued, not refused** (since 2026-10-23): the answer is the usual `request_id` with status `queued`, and the request starts when one of the account's running requests ends.
- **The queue has a limit too:** a multiple of the concurrency limit, with each output of a batch request counted apart. A generation request to a full queue is refused, and nothing is created or charged:

  ```http
  HTTP/1.1 429 Too Many Requests
  Retry-After: 30
  ```

  ```json
  {"detail": {"code": "account_queue_full", "message": "Too many queued generations for this account",
    "retryable": true, "limit": 40, "retry_after_seconds": 30}}
  ```

  `limit` is the account's queue limit. The docs ask to wait `Retry-After` seconds and submit again with the same `Idempotency-Key`.
- **Queue admission outage:** `503` with `"code": "admission_control_unavailable"` and `"retryable": true`; retry with backoff.
- **Endpoint limits:** some endpoints that aren't generations refuse above their limit instead of queuing, with `429` and `Retry-After`. The only one listed is `POST /v1/custom-references` (Soul ID references training at once), whose `detail` is still the text `"Maximum number of concurrent requests (2) has been reached"`; it answered `400` with that text before 2026-10-23. Jutsu doesn't call it.

What Jutsu does (`HiggsfieldAPIErrors`, `JobEngine+Recover`):
- Any `429` maps to `.concurrencyLimit(retryAfter:)`. The wait is `Retry-After` in seconds; when the header is missing or isn't a number (the HTTP-date form isn't read), the body's `retry_after_seconds`; else none, and the engine's own retry backoff applies.
- The engine releases the job's slot, puts it back to `waitingForSlot` and sends the same submit, with the same `Idempotency-Key`, after the server's wait, kept within 1 s and 10 min (`EngineSettings.serverRetryDelay`); jitter only lengthens it, within that range. A full queue never counts toward the "kept failing" pause: the job waits as long as it takes.
- The app's own concurrency setting (`SlotLimiter`) is what keeps the queue short; nothing reported by the server changes it. A `400` with the old concurrency text is now a plain validation error.
- `503` `admission_control_unavailable` maps to `.server(status: 503)` and is retried with backoff; any other `503` is `.modelUnavailable`.

### 3.12 Billing and retention

- Credits expire one year after they're added.
- Only successful requests are charged.
- Jutsu downloads every result as soon as it completes.

Data retention (`docs/enterprise/data-retention`, added 2026-10-24). Status: **Documented**; Jutsu doesn't use any of it yet.

- A request's input files, outputs, prompt and parameters are kept **7 days by default**, counted from when it finishes (`completed`, `failed`, `nsfw` or `canceled`). Higgsfield can set an account retention of 1 hour to 7 days on request; it applies to new requests only.
- `Hf-Expires-After: <seconds>` on a generation submit shortens it for that request: at least 3600 and at most the account retention, else `422`. The header is part of the idempotency fingerprint, so a retry must send the same value.
- The submit answer adds `expires_after` (the period that applies). Once the request finishes, the status answer and the webhook add `expires_at`; after it the output URLs stop working, while the status call still returns the request.
- `DELETE /requests/{request_id}` deletes a finished request's files, prompt and parameters at once: `200 {"request_id", "status": "deleted"}`, the same on a repeat; `404` for a request that doesn't exist or belongs to another account; `409` while it is `queued` or `in_progress`; `503` when deletion is briefly unavailable. The request ID, model, status, timestamps and billing records stay.
- Files uploaded with `/files/generate-upload-url` are stored apart from a request and deleted within 7 days.
- Jutsu sends no `Hf-Expires-After`, doesn't read `expires_after` or `expires_at`, and never deletes a request. A download's `403` is retried as an expired signed URL for 7 days after the result (`ARCHITECTURE.md`, Downloads), which assumes the default retention (open question 14 in 6).

### 3.13 Endpoints Jutsu uses

Status: **Verified**.

| Purpose | Method and path |
|---|---|
| Motion Transfer | `POST /higgsfield/genjutsu/motion-transfer/v1.0` |
| Object Swap | `POST /higgsfield/genjutsu/object-swap/v1.0` |
| Restyle | `POST /higgsfield/genjutsu/restyle/v1.0` |
| Restyle presets | `GET /models/higgsfield/genjutsu/restyle/v1.0/presets` → `{"items": [{"id", "name", "preview_url"}]}` |
| Upload | `POST /files/generate-upload-url`, then `PUT` the presigned URL |
| Estimate | `POST /estimate/{endpoint}` |
| Status | `GET /requests/{id}/status` |
| Cancel | `POST /requests/{id}/cancel` |

Genjutsu request bodies:

| Field | Motion Transfer | Object Swap | Restyle |
|---|---|---|---|
| `video_url` | required | required | required |
| `image_urls` | required, 1–8 | required, 1–8 | optional, 0–5 (`[]` keeps the source's subjects) |
| `preset_id` | — (omit) | — (omit) | required, UUID from the presets endpoint |
| `prompt` | optional, `""`, ≤10,000 chars | optional, `""` | optional, `""` |
| `resolution` | `480p` / `720p` (default) / `1080p` | same | same |

Source rules:
- All three Genjutsu workflows need a source of at least 4 s. Longer sources are trimmed to 30 s, and the output length follows the trimmed source.
- Object Swap needs at least 409,600 pixels per frame (width × height).
- Restyle accepts at most 200 MiB. It keeps the source audio, and its output FPS and duration can differ from the source.
- The old misspelled IDs `higgsfiled/genjutsu/…/v1.0` still work but are hidden from discovery. Use `higgsfield/…`.

List price (`pricing.json`, 2026-10-13), per second of source rounded up: 480p $0.318, 720p $0.681, 1080p $1.632.

Seedance 2.5 and Kling 3.0 Motion Control (issue #38). Status: **Documented**; not yet run against the live API.

| Jutsu job | Endpoint | Body (`SeedanceRequest`, `SeedanceFramesRequest`, `KlingMotionRequest`) |
|---|---|---|
| Seedance, no source and no images | `POST /bytedance/seedance-2.5/text-to-video` | `prompt`* (min 1 char), `duration` 4–30, `resolution`, `aspect_ratio`, `generate_audio`, `bitrate_mode` |
| Seedance with a source or images | `POST /bytedance/seedance-2.5/reference-to-video` | `video_urls` (the source first), `image_urls`, at least one non-empty; `prompt` (omitted when empty), `duration`, `resolution`, `aspect_ratio`, `generate_audio`, `bitrate_mode` |
| Seedance from a start frame (issue #40) | `POST /bytedance/seedance-2.5/image-to-video` | `image_url`* (the start frame), `end_image_url` (the end frame, omitted when there is none), `prompt` (omitted when empty), `duration` 4–30, `resolution`, `generate_audio`, `bitrate_mode`. No `aspect_ratio`: the output's frame follows the start image |
| Seedance Edit (issue #39) | `POST /bytedance/seedance-2.5/video-edit` | `prompt`* (min 1 char), `video_url`* (the source selection), `image_urls` (omitted when empty), `resolution`, `generate_audio` (`false` unless the job asks for a generated soundtrack: the source's sound is put back after download), `bitrate_mode`. No `duration`: the output follows the source, normalized to at least 4 s |
| Seedance Extend (issue #39) | `POST /bytedance/seedance-2.5/video-extend` | same body (`SeedanceVideoRequest`), plus `duration` 4–30 (default 5): the length of the new part; `generate_audio` is `true` unless the job is muted, since no source sound belongs to the new part |
| Kling below 1080p | `POST /kling-video/v3/motion-control/std` | `image_url`* (the one reference), `video_url`* (3–30 s), `prompt` (omitted when empty), `keep_original_sound`, `character_orientation` |
| Kling at 1080p | `POST /kling-video/v3/motion-control/pro` | same |
| Kling O3 (issue #48) | `POST /kling-video/o3/video-reference` | `prompt`*, `video_urls`* (the source, exactly one), `image_urls` (0–4, omitted when empty), `mode` (`std` below 1080p, `pro` at 1080p), `duration` 3–10 (the selection's seconds, rounded up). `elements` and `aspect_ratio` aren't sent (`KlingVideoReferenceRequest`) |
| Kling O3 Edit (issue #101) | `POST /kling-video/o3/video-edit` | `prompt`* (≤2,500 chars), `video_urls`* (the source, exactly one, 3–15.5 s, ≤200 MB), `image_urls` (0–4, omitted when empty), `mode` (`std` below 1080p, `pro` at 1080p; `4k` isn't offered). No `duration`: the output follows the source (`KlingVideoEditRequest`) |
| Kling 2.6 below 1080p (issue #101) | `POST /kling-video/motion-control/std` | Kling 3.0's body (`KlingMotionRequest`) |
| Kling 2.6 at 1080p | `POST /kling-video/motion-control/pro` | same |
| Wan 3.0 / 3.0 Prime (issue #101) | `POST /alibaba/wan-3.0/reference-to-video`, `POST /alibaba/wan-3.0-prime/reference-to-video` | `prompt`*, `video_urls` (the source; up to 5 clips of 1–30 s, 30 s in all), `image_urls` (0–10), `duration` 2–30, `resolution` 480p/720p/1080p, `generate_audio`. `aspect_ratio` isn't sent, so the default `adaptive` follows the references; `seed`, `file_url`, `link_url`, `audio_urls` and `enable_thinking` aren't sent (`ReferenceToVideoRequest`) |
| Wan 2.7 (issue #101) | `POST /wan/v2.7/reference-to-video` | `prompt`*, `video_urls` (the source), `image_urls` (images and videos 5 at most), `duration` 2–10, `resolution` 720p or 1080p only, `aspect_ratio` 16:9 or 9:16 (the one nearest the source). No `generate_audio`; `seed`, `prompt_extend` and `negative_prompt` aren't sent. Empty arrays are refused, so they are left out |
| Cinema Studio 4.0 (issue #101) | `POST /higgsfield/cinema-studio/4.0` | `prompt`* (min 1 char, non-blank), `video_urls` (the source; ≤10), `image_urls` (≤30), `duration` 4–30, `resolution` 480p or 720p only, `aspect_ratio` (21:9, 16:9, 4:3, 1:1, 3:4, 9:16; no `auto`, so the one nearest the source), `generate_audio`, and the creative controls the job sets (below). No `mode`: media make it reference-to-video. `audio_urls` aren't sent. Unknown keys are refused |
| MiniMax H3 (issue #101) | `POST /minimax/h3/reference-to-video` | `prompt`* (min 1 char; the provider reads the first 7,000), `video_urls` (the source; 1–3 when sent), `image_urls` (1–9 when sent; Jutsu takes up to 5, see the price below), `duration` 5–15 (default 5), `resolution` `"2K"` only (case-sensitive). `aspect_ratio` (`auto` default, `adaptive`, 21:9 … 9:16) isn't sent, so `auto` follows the references; no `generate_audio`; `audio_urls` and `aigc_watermark` aren't sent. At least one image or video is required; the schema forbids unknown keys (`ReferenceToVideoRequest`, shape `wanReference`). MiniMax H3 Max has no REST endpoint: the public docs list only H3 |

- Cinema Studio's creative controls (issue #101), from the docs' Generate page (2026-10-15). Each is one of the schema's values or left out, and the director picks what is left out; the schema takes no `"auto"`. Create's **Direction** row under the model picker opens a menu per control, on Auto until set (`CinemaControls`, stored in the job and its template as the body's fields; a field or value another version wrote is dropped on read):
  - `camera_model`: `modern`, `35mm-film`, `8mm-film`, `dv-camcorder`;
  - `camera_lens`: `clean-sharp`, `anamorphic`, `vintage-anamorphic`, `warm-vintage`, `halation-vintage`;
  - `camera_aperture`: `f14-wide-open`, `f4-moderate`, `f11-deep-focus`;
  - `camera_movement`: 33 moves (`dolly-in`, `whip-pan`, `drone-orbit`, `static-shot`, …);
  - `genre`: `epic`, `drama`, `noir`, `comedy`, `horror`, `action`;
  - `era`: `1960s`, `1980s`, `1990s`, `2000s`, `2020s`;
  - `light`: `silhouette`, `practicals`, `window`, `overhead-fall`, `contre-jour`, `soft-cross`;
  - `pacing`: `chaotic`, `dynamic`, `calm`, `single-shot`;
  - `color_palette`: 50 named palettes (`neon-rain-at-midnight`, `yellow-room`, …).
  Their titles are `cinemaStudio4.<field>` and `cinemaStudio4.<field>.<value>` in `Models.xcstrings`. On the account they aren't sent (4.4).
- All five Seedance schemas forbid unknown keys, and the arrays have `minItems: 1`, so empty arrays and an empty prompt are left out. `audio_urls` aren't sent, nor are Edit's and Extend's extra `video_urls` (at most 9 besides the source; 50 media items in all).
- `bitrate_mode` (`standard` or `high`, default `high`) is Create's **Quality: Standard / High bitrate** under Resolution, High until changed; a job made before it existed leaves it out. The public price doesn't depend on it, so the list price stays the same and `/estimate` quotes the exact body.
- Start and end frame (issue #40): Create offers two optional slots above the references for Seedance without a source. Filling one runs the job on `image-to-video` and sets the references aside (they stay in the form); an end frame alone is refused before submit, since `image_url` is required. The frames travel as the job's first and second reference with `JobSpec.referencesAreFrames`, so upload, templates and Duplicate handle them like references.
- Edit and Extend take public media URLs only, and trim or pad videos to a 30 s budget. Output framing follows the source, so no `aspect_ratio`.
- Whether Extend returns only the new part or the whole clip isn't documented. Jutsu assumes the new part (as the issue says) and offers **Join with Original…** on the result page, which puts the source selection in front of it locally (`ClipJoiner`). Confirm on the first live run.
- `aspect_ratio` has no `auto` and defaults to `16:9`. Jutsu sends the ratio nearest the source's frame for a clip from a source, the ratio asked for otherwise, and nothing for Auto. Whether a reference video sets the frame on its own, as on the MCP server, isn't documented.
- `generate_audio` is `true` without a source and for Extend unless the job is muted, and with a source only for the Audio option **Generated** (issue #23); otherwise the source's sound is put back after download. Same on the account (`AccountModel.generatesAudio`).
- Kling has no `duration` (the output follows the source) and no background parameter, so "Keep the video's background" is off with an API key. `keep_original_sound` is `yes` for the Audio option Original (the server keeps the source's sound in sync, nothing is re-muxed) and `no` for Mute and Fade out (the result comes back silent, and Fade out puts the faded source sound on it after download). `character_orientation` is Create's **Character faces: As in image / As in video**, As in video (the server's default) until changed; a job made before it existed leaves it out.
- List price (`pricing.json`, 2026-10-15, before discounts, from open.higgsfield.ai). Seedance, per second of output for 16:9 (it bills tokens of the output frame): 480p $0.2056, 720p $0.4622, 1080p $1.1372; the same for `image-to-video` (its open.higgsfield.ai page, 2026-10-15: images aren't billed as video input). With a source video the input seconds are billed too and both at 0.6 of the rate, so 1.2 times: $0.24672, $0.55464, $1.36464. Kling per second: Standard $0.126, Pro $0.168. Kling O3 video reference: see the table below. All are shown as estimates; `serverEstimate` replaces them after upload.
- Issue #101 list prices (open.higgsfield.ai, 2026-10-15, before the 50% discount the pages show): Kling 2.6 Motion Control Standard $0.07, Pro $0.112 per second; Wan 2.7 720p $0.10, 1080p $0.15.
- Issue #113 rates, read on 2026-10-15 from `https://open.higgsfield.ai/pricing` and the public JSON it is built from, `https://dash.higgsfield.ai/api/v2/pricing/models/?page_size=50` (each model's `modes[].pricing.options[]`: `original_amount` is the list price, `amount` today's, `configuration` the setting it is for). `pricing.json` keeps the list price, before discounts, so a discount never makes it read lower than the bill. Where only a range over all settings is published, it takes the top of the range as `{"upTo": rate}` (`Pricing.upperBounds`): Create says "up to $X" and rounds it up, the job's price is an estimate, and `/estimate` prices the uploaded files before submit.

| Tariff (`pricing.json`) | 480p | 720p | 1080p | What is published |
|---|---|---|---|---|
| `alibaba/wan-3.0/reference-to-video` | $0.05 | $0.10 | $0.20 | One rate per resolution (60% off until 2026-11-01, then 50%) |
| `alibaba/wan-3.0-prime/reference-to-video` | $0.068 | $0.14 | $0.28 | One rate per resolution (60% off until 2026-11-01, then 40%) |
| `higgsfield/cinema-studio/4.0` | up to $0.4623 | up to $0.4623 | — | A range only: from $0.2057 (480p, 4 s) to $0.4623 (720p, 30 s), no discount |
| `kling-video/o3/video-reference` (std below 1080p, pro at 1080p) | up to $0.168 | up to $0.168 | up to $0.168 | A range only, $0.126–$0.168, by length; no price names a `mode` (before the 50% discount) |
| `kling-video/o3/video-edit` | up to $0.126 | up to $0.126 | unpriced (`null`) | One "exact" $0.126 that names no `mode`, whose default is `pro` (before the 50% discount). It is taken as the top for Standard. Pro has no published rate, and the account quotes Pro at 4/3 of Standard (12 s: 18 and 24 credits), so $0.126 could be below it: Pro stays **Price unknown** until `/estimate` |
| `minimax/h3/reference-to-video` | — | — | — | 2K only: $0.13 per generated second, "exact" at 1, 10 and 15 s (50% off now, $0.065). The model page adds $0.08 for each reference image past the fifth, which a per-second rate can't hold, so Jutsu takes at most five images and the rate is the whole price |

- An unpriced rate (`null`, `Pricing.unpriced`) makes the cost line say **Price unknown**; the price is `Cost.unknownUSD` (never $0), a spend cap asks before such a job starts, and `/estimate` prices the uploaded files.
- Per-model resolutions (issue #101): `models.json`'s `resolutions` lists them when a model lacks some of 480p, 720p and 1080p (`Resolution.standard`; Wan 2.7: 720p and 1080p; Cinema Studio: 480p and 720p, the REST schema's list; MiniMax H3: `2K`; MiniMax H3 Max: 480p and 768p). `Resolution` also has 768p and 2K for MiniMax, sent as the schemas spell them (`"768p"`, `"2K"`). The resolution picker offers a model's own, a job is made at the nearest by frame height (`VideoModel.fitted` with `Resolution.pixelHeight`, 2K taken as 1440; the higher on a tie), and `Pricing` needs rates only for them. Settings' default and draft resolutions stay 480p, 720p and 1080p, and a reframe of a 768p or 2K result asks `reframe` for 720p or 1080p (`Resolution.standardized`), the only values it takes.
- A model with no REST endpoint (`models.json` `request.endpoints` empty: MiniMax H3 Max, and Genjutsu Lite until its request schema is published) runs on the account only: `VideoModel.runsWithAPIKey` is false, an API key's capabilities leave it out, and `Pricing` has no tariff for it.
- Edit and Extend list prices (open.higgsfield.ai `video-edit` and `video-extend` pages, 2026-10-15): video input is required, and each 1,000 video tokens cost $0.01284 at 480p and 720p and $0.01404 at 1080p, 0.6 of the rate without video input; tokens = ceil(height × width × (input seconds + generated seconds) × 24 / 1024). For 16:9 that is about $0.1234, $0.2773 and $0.6823 per second of input and output together. Edit's output is as long as its source, so `pricing.json` prices it per second of source at 1.2 times the rate (as "with video reference"); Extend at 0.6 times on the source selection plus the added part (`Pricing.billedSeconds(for:)`).

Reference images (issue #42). Status: **Documented** (docs.higgsfield.ai model pages, 2026-10-15); not yet run against the live API. Create's References › Generate… sends them through the same lifecycle: `/estimate/{endpoint}` with the same body before Generate, submit with an `Idempotency-Key`, `requests/{id}/status` until `images[].url`, cancel while queued. They never enter the job queue.

| Model | Endpoint | Body (`SoulImageRequest`, `GrokImageRequest`, `QwenEditRequest`) | List price (open.higgsfield.ai, 2026-10-15) |
|---|---|---|---|
| Soul 2 | `POST /higgsfield-ai/soul/v2/standard` | `prompt`*, `aspect_ratio`, `batch_size` 1 or 4 (the schema's enum; the model page: "1 or 4 only") | $0.0032 an image at 720p (the default; $0.0057 at 1080p) |
| Grok Image 2 (generate and edit) | `POST /xai/grok-imagine-image-2.0` | `prompt`*, `aspect_ratio`, `image_urls` (omitted when empty; an image to edit) | $0.04 at 1k low, $0.08 at 2k medium; the default's price isn't published, so Jutsu shows $0.08 |
| Qwen Image 3 Edit | `POST /alibaba/qwen-image-3/edit` | `prompt`*, `image_urls`* (one image), `aspect_ratio` | $0.04 at 1k, $0.075 at 2k |

- One image per request except Soul 2's `batch_size`, which takes 1 or 4 (re-checked 2026-10-28; Create offers those two, `APIImageModel` `variantCounts`); Grok and Qwen offer one variant.
- The list price is shown as an estimate until `/estimate` answers, and when it can't (network or server error).
- `quality`, `resolution`, `seed`, `negative_prompt` and the Soul style and character fields aren't sent: the server's defaults apply.

### 3.14 Other documented endpoints

Status: **Documented**. Jutsu doesn't use these yet.

- **Model endpoints:** every endpoint in [Appendix A](#appendix-a-rest-model-catalog) follows 3.2–3.10.
- **Soul ID (character training):**
  - `POST /v1/custom-references` with `{"name": "…" (≤100), "model_version": …, "input_images": [{"type": "image_url", "image_url": "https://…"}]}` (1–100 images);
  - then poll `GET /v1/custom-references/{id}`: `not_ready`, `queued`, `in_progress`, `completed` or `failed`;
  - Soul image models take the result as `custom_reference_id`;
  - with the account's maximum of references already training, the create answers `429` with `Retry-After` (since 2026-10-23; `400` before), see 3.11.
- **Kling 4.0** (open.higgsfield.ai model pages, released 2026-10-23; not in docs.higgsfield.ai's model catalog on 2026-10-28). Four endpoints, each 3–30 s, `resolution` `720p` or `1080p` (default), `aspect_ratio` `21:9`, `16:9`, `9:16`, `1:1` or `adaptive` (default):
  - `kling-video/v4.0/text-to-video` and `kling-video/v4.0/image-to-video`: $0.157–$0.235 a second (720p–1080p);
  - `kling-video/v4.0/reference-to-video`: `prompt`*, `image_urls` (≤10) and `video_urls` (≤5, references, not a source to edit; longer than 30 s is trimmed), at least one non-empty; `duration` 3–30 (default 10); references are named `@image_1`, `@video_1`… in the prompt; $0.094–$0.235 a second;
  - `kling-video/v4.0/video-edit`: `prompt`*, `video_url`* (the clip to edit), up to 10 images or videos as references, `duration`, `resolution`, `aspect_ratio`; $0.094 (720p) or $0.141 (1080p) a second, billed on the output's length plus the longer of the input videos' total and the output.
  - Prices are list prices before the page's 30% discount. Not used by Jutsu yet: the bodies are only on the model pages, and none has been run.

Models in the catalog that are closest to what Jutsu does (issues #39, #48):

| Model | Endpoint | Inputs that matter |
|---|---|---|
| Seedance 2.5 edit | `bytedance/seedance-2.5/video-edit` | Used since issue #39 (3.13) |
| Seedance 2.5 extend | `bytedance/seedance-2.5/video-extend` | Used since issue #39 (3.13) |
| Seedance 2.5 image | `bytedance/seedance-2.5/image-to-video` | Used since issue #40 (3.13) |
| Kling 2.6 Motion Control | `kling-video/motion-control/{std,pro}` | Used since issue #101 (3.13): `image_url`* (≤10 MB, 300–65,536 px per side), `video_url`* (3–30 s), `prompt`, `keep_original_sound` yes/no (default yes), `character_orientation` image/video; no `duration` |
| Kling O3 video reference | `kling-video/o3/video-reference` | `video_urls`*, `prompt`*, `mode` std/pro, `duration` 3–10, `elements`, `image_urls` |
| Kling O3 video edit | `kling-video/o3/video-edit` | Used since issue #101 (3.13) |
| Wan 3.0 / 3.0 Prime reference | `alibaba/wan-3.0[-prime]/reference-to-video` | Used since issue #101 (3.13) |
| Wan 2.7 reference | `wan/v2.7/reference-to-video` | Used since issue #101 (3.13) |
| MiniMax H3 reference | `minimax/h3/reference-to-video` | Used since issue #101 (3.13) |
| Cinema Studio 4.0 | `higgsfield/cinema-studio/4.0` | Used since issue #101 (3.13), with the creative controls; `<<<video_1>>>` style tokens may name the references in the prompt |

Media URLs for these must be public HTTPS URLs; `asset://` references are rejected.

---

## 4. MCP server

### 4.1 Endpoint and transport

- **URL:** `https://mcp.higgsfield.ai/mcp`
- **Transport:** MCP Streamable HTTP. Every message is a `POST` with `Accept: application/json, text/event-stream`; answers come as JSON or as an SSE stream.
- **Protocol version:** `2025-06-18`. The client rejects an incompatible `initialize` result. Every subsequent request carries `MCP-Protocol-Version`, including on a stateless server; `Mcp-Session-Id` is included only when initialization assigned one. A failed handshake discards its session.
- **Calls Jutsu makes:** `initialize` (client info `Jutsu Studio`), `notifications/initialized`, `tools/list` (paged by `nextCursor`, capped at 50 pages) and `tools/call`.

Client behaviour (`Packages/HiggsfieldKit/Sources/HiggsfieldMCP/MCPClient.swift`):
- It initializes lazily on the first call.
- `404` to a request with a session ID means the session ended and the request wasn't processed. The client starts a new session and resends once.
- `401` refreshes the access token once and retries. A second `401`, or a `403`, maps to `HiggsfieldError.unauthorized`.
- An SSE answer is read until the reply with the request's `id` arrives, not until the stream closes. Server notifications before it are skipped.
- Each request has a 120 s overall timeout.
- JSON-RPC errors are thrown as `JSONRPCError {code, message}`.

### 4.2 Authorization

Status: **Verified**, from public metadata on 2026-10-14; re-read on 2026-10-28.

An unauthenticated request gets `401` with:

```http
WWW-Authenticate: Bearer resource_metadata="https://mcp.higgsfield.ai/.well-known/oauth-protected-resource/mcp", scope="openid email offline_access"
```

Protected resource metadata (RFC 9728):

```json
{
  "resource": "https://mcp.higgsfield.ai/mcp",
  "authorization_servers": ["https://clerk.higgsfield.ai"],
  "scopes_supported": ["openid", "email", "offline_access"],
  "bearer_methods_supported": ["header"],
  "higgsfield_auth_hints": {
    "selection": "client_capability_based",
    "options": [
      { "flow": "authorization_code_pkce", "authorization_server": "https://clerk.higgsfield.ai", "…": "…" }
    ]
  }
}
```

Authorization server `https://clerk.higgsfield.ai` (`/.well-known/oauth-authorization-server`):

| Field | Value |
|---|---|
| `authorization_endpoint` | `https://clerk.higgsfield.ai/oauth/authorize` |
| `token_endpoint` | `https://clerk.higgsfield.ai/oauth/token` |
| `registration_endpoint` | `https://clerk.higgsfield.ai/oauth/register` |
| `revocation_endpoint` | `https://clerk.higgsfield.ai/oauth/token/revoke` |
| `code_challenge_methods_supported` | `S256` |
| `grant_types_supported` | `authorization_code`, `refresh_token`, `urn:ietf:params:oauth:grant-type:device_code` |
| `token_endpoint_auth_methods_supported` | `none`, `client_secret_basic`, `client_secret_post` |
| `client_id_metadata_document_supported` | `true` |
| `scopes_supported` | `openid`, `profile`, `email`, `public_metadata`, `private_metadata`, `offline_access`, `user:org:read` |

How Jutsu signs in (`OAuthDiscovery`, `ClientRegistration`, `PKCEAuthorizer`, `OAuthClient`, `LoopbackAuthorizationPresenter`):

1. **Discovery.** Read `resource_metadata` from the 401, fetch it, then fetch the first authorization server's metadata.
2. **Client ID.** The Client ID Metadata Document below when the server supports it; otherwise dynamic client registration (RFC 7591) as a public client:
   - request: `client_name: "Jutsu Studio"`, `token_endpoint_auth_method: "none"`, grants `authorization_code` + `refresh_token`;
   - redirects: `http://127.0.0.1:{47613,51874,58329}/callback` (RFC 8252 loopback, fixed ports so they match exactly);
   - a `client_id` registered earlier at the same issuer is reused.

   Client ID Metadata Document: when the server advertises `client_id_metadata_document_supported`, `client_id` is `https://jutsuhq.github.io/jutsu-studio/oauth-client.json`, which GitHub Pages serves from `docs/oauth-client.json`. Registration remains the fallback. Checked on 2026-10-16: with that `client_id`, `/oauth/authorize` leads to Higgsfield's sign-in page, while an unpublished URL gets 401.
3. **Authorization.** Authorization code with PKCE S256 and `state`. Scope `openid email offline_access`, with `resource=https://mcp.higgsfield.ai/mcp` (RFC 8707) on both the authorize and token requests. The browser returns the code to a listener on the first free loopback port.
4. **Tokens.** Stored in the Keychain and refreshed with `refresh_token`. The ID token gives the account's email for display.

Until 2026-10 the metadata also listed `https://fnf-device-auth.higgsfield.ai` with a `device_code` option; on 2026-10-28 it lists only `clerk.higgsfield.ai`, whose own metadata has a `device_authorization_endpoint` (`https://clerk.higgsfield.ai/oauth/device_authorization`) as before. Jutsu reads the first authorization server, so sign-in is unchanged, and it doesn't use the device-code flow.

### 4.3 Tool calls and results

`tools/call` returns `MCPToolResult`. Jutsu reads `structuredContent` when it's present; otherwise it parses the first text `content` item as JSON, or keeps it as a string. An `isError: true` result from a tool that can start a generation is ambiguous unless the call was only a quote or the text starts with one of Higgsfield's wordings for a refusal before execution, both seen live on 2026-10-15: `Invalid request:` (an unknown model answered `Invalid request: unknown model …`) and `Error starting generation: Unlimited generations aren't supported` (a refused `use_unlim`, issue #114; balance and `transactions` showed nothing charged). Any other `isError` becomes `HiggsfieldError.server(status: 200)`, so a paid submit becomes `outcomeUnknown` and isn't resent. A refusal stays a validation error with its text (`HiggsfieldAccount.refusalPrefixes`). Read-only tool errors remain validation errors with the joined text blocks. JSON-RPC codes `-32600`, `-32601` and `-32602` are refusals before execution; internal and unknown codes are ambiguous (`MCPTool.swift`, `HiggsfieldAccount.callResult`, `mapErrors`). The app finds tools by name, rechecks optional tools (`balance`, history, galleries) at most once a minute, and hides a feature when its tool is missing (`HiggsfieldAccount.refreshTools`, `ToolRole`).

### 4.4 Tools Jutsu uses

Status: **Verified** 2026-10-14 (`Packages/HiggsfieldKit/Sources/HiggsfieldMCP/ToolCatalog.swift`).

| Tool | Arguments Jutsu sends | What Jutsu reads |
|---|---|---|
| `generate_video` | `{"params": {…}}`, see [4.5](#45-generate_video) | `results[0].id` (job ID), `request_id`; with `get_cost`: `cost.credits_exact` or `cost.credits` |
| `media_upload` | `filename`, `content_type` | `uploads[0].media_id`, `.upload_url` (must be HTTPS), `.url` |
| `media_confirm` | `media_id`, `type` (`image`/`video`) | `error` if refused |
| `job_status` | `jobId` | `generation.status`, `generation.results.rawUrl`, `generation.error` |
| `balance` | — | `credits`, `subscription_plan_type` (for example `creator_plus`) |
| `show_generations` | `size` 1–100, `only_completed`, optional `type` (`video`/`image`/`audio`/`3d`), `cursor` | `items[]` (`id`, `type`, `status`, `model`, `createdAt`, `liked`, `results.rawUrl`, `width`, `height`, `duration`, `prompt`, `resolution`, `medias`), `next_cursor`. `width`, `height` and `duration` are the job's params and can be wrong (4.6), so they are only shown until the file is downloaded; the import reads the file's own (`Job.outputMedia`) |
| `set_generation_like` | `job_id`, `liked` | — |
| `transactions` | `size` 1–100, `cursor` | `items[]` (`created_at`, `credits` (negative for spend), `action` spend/refund/grant/deduct, `display_name`), `next_cursor` |
| `assets_picker_list` | `source: "uploads"`, `kind` `image`/`video`, `size` ≤50, `cursor` | `items[]` (`id` = media_id, `kind`, `url`, `thumbnailUrl`, `width`, `height`, `duration`, `created_at`), `next_cursor` |
| `get_presets` | `source: "genjutsu"`, `category`, `limit` ≤50, `cursor` | `items[]` (`id`, `name`, `thumbnail_url`, `preview_url`, `description`), `next_cursor` |
| `get_presets` (priced detail) | `source: "genjutsu"`, `preset_id`, `category: "all"`, `initial_inputs` | `structuredContent.execution.cost_credits` (or `cost_credits:` in the text) |
| `execute_preset` | `source: "genjutsu"`, `preset_id`, `inputs: {video: [media_id], references: [media_id…], prompt, resolution}` | live (2026-10-15): `{source: "marketing_studio", preset_id, job_ids: [id], status: "submitted"}`; the job ID is read from `job_ids[0]`, then `job_ids[0].id`, `jobs[0].id`, `results[0].id` or `job_id` |

Notes:

- **Upload flow:** `media_upload` → `PUT` bytes to `upload_url` → `media_confirm` → use `media_id` in `medias`.
- **Job statuses:**
  - `queued` / `pending` → `.queued`
  - `in_progress` / `processing` → `.inProgress`
  - `completed` → `.completed`
  - `failed` → `.failed`
  - `nsfw` → `.rejected(.explicitContent)`
  - `ip_detected` → `.rejected(.protectedContent)`
  - `canceled` → `.canceled`
  - anything else → `.inProgress`

  A `completed` job without an HTTPS `rawUrl` is an error. No cancel tool is known, so `HiggsfieldMCPProvider.cancel` throws `notCancellable` and the app doesn't offer Cancel for account jobs once they're submitted.
- **Genjutsu galleries:** `get_presets` categories `genjutsu` (Motion Library, picked by Higgsfield), `genjutsu-trending`, `genjutsu-new` and `genjutsu-styles` (Restyle looks).
  - IDs look like `genjutsu:<uuid>`, `genjutsu:trending:<uuid>` or `genjutsu-style:<uuid>`.
  - A motion entry names its source clip only inside `description` ("… Driving video: https://….mp4 …").
  - Styles run with `execute_preset`; motion entries are example sources for a normal `generate_video`.
- **Server media URLs** are accepted only over HTTPS (`URL(serverMedia:)`).

**Polling with `jobs_wait` (issue #44): confirmed live on 2026-10-15** (issue #114; `docs/mcp-snapshots/live-2026-10-15/jobs_wait_running.json` and `jobs_wait_completed.json`). The engine groups the account's `queued` and `processing` jobs into sets of at most 12 (`HiggsfieldAccount.jobsWaitLimit`, the schema's `maxItems`) and asks one `jobs_wait` per set and tick instead of one `job_status` per job (`JobEngine+StatusBatch`, `HiggsfieldMCPProvider.statuses(of:)`, `JobsWait`). It sleeps between ticks as long as `poll_after_seconds` asks, kept within 1–30 s (`EngineSettings.serverPollDelay`), or, when the answer doesn't say, with the usual polling backoff.

- **Request (confirmed):** `{"jobs": [{"job_id": "<uuid>", "index": 0}, …]}`, 1–12 items, both keys required (`additionalProperties: false`); `index` is the job's place in the set. `timeout_seconds` (0–15, default 15) is left out, so the server holds the call up to 15 s. A `jobs_wait` whose schema has no `jobs` counts as missing. Read-only and idempotent (`readOnlyHint`, `idempotentHint`). The first guess (#94) sent plain IDs under `job_ids`/`jobIds`/`ids`/`jobs`, which the live schema refuses.
- **Answer (confirmed live on 2026-10-15, ten jobs: Seedance variants, Edit, Extend and frames, two Soul 2 images and three operations):** `{jobs: [{index, job_id, status, type, model, result_url}], summary: {total, completed, failed, active, errors}, all_terminal, timed_out, poll_after_seconds}`, as the `outputSchema` declares (which also names `thumbnail_url`, `exr_url`, `error`, `retryable` and `aborted`). `status` is `in_progress` while a job runs and `completed`, with `result_url`, once it is done; `lookup_failed` (with `retryable`) is the schema's. The call held for about 15 s (`timed_out: true`) and asked for `poll_after_seconds: 10` while jobs ran; the answer with every job done had `all_terminal: true` and no `poll_after_seconds`. **`type` isn't the result's kind until the job ends:** running Seedance jobs said `"image"` and only completed ones `"video"`, so Jutsu never reads it. The app reads each job's `status` like `job_status` (4.4 above) and the file from `result_url`. Older guessed shapes are still read: the jobs under `jobs`, `results`, `items`, `data` or `generations` (or an object by job ID), the ID in `job_id`, `id` or `jobId`, the job or its `generation`, the file in `results.rawUrl`. `all_terminal` and `summary` aren't needed, each job's own status says whether it ended.

Every failure falls back to `job_status`, so a wrong reading costs calls, never a stalled job: without the tool, each job is polled alone; a failed call (error, `isError`, 5xx) falls back for that tick; an answer that names none of the jobs asked about switches the connection to `job_status` until the next sign-in (logged as "jobs_wait answered in an unknown shape"); a job missing from an answer, without a `status` string, with `lookup_failed`, or completed without an HTTPS file is asked about alone. The API key polls each job, as before.

A live answer, trimmed to two jobs:

```json
{
  "jobs": [
    { "index": 0, "job_id": "<uuid>", "status": "in_progress", "type": "image", "model": "seedance_2_5" },
    { "index": 1, "job_id": "<uuid>", "status": "completed", "type": "video", "model": "video_background_remover",
      "result_url": "https://…/hf_20261015_132302_<uuid>.mp4" }
  ],
  "summary": { "total": 2, "completed": 1, "failed": 0, "active": 1, "errors": 0 },
  "all_terminal": false,
  "timed_out": true,
  "poll_after_seconds": 10
}
```

**Variants (`generate_video` `count`, issue #44): confirmed live on 2026-10-15 (issue #114).** The snapshot documents `params.count`, an integer 1–4 (default 1), "variants generated from this same prompt, inputs, and settings and rendered together in one widget". With `use_unlim: true` (and `use_free_gens`) it is capped to 1 and the cap is reported in `adjustments`. The answer's `results[]` items each carry an `id`, `status` and `model`, so each variant is read as its own job to poll.

- **Create.** On an account, a Variants stepper (1–4) beside the Draft and Generate buttons (`CreateForm.variants`, `variants(in:)`). It is held at 1 with the reason for a Genjutsu Style (`execute_preset` has no `count`), a batch (one video per style or character), a job the unlimited allowance pays (the server caps it), and an account whose `generate_video` is missing (`Capabilities.maxVariants`). An API key hides it: REST makes one generation per request, and `HiggsfieldAPIProvider` refuses `JobSpec.variants` > 1 before anything is sent. Operations on a result make one.
- **Request.** `count` is sent only above 1 and never with `use_unlim` (`VideoRequest.count`). The engine also sets a job the allowance pays to 1 variant when it is queued.
- **Price.** The quote is one variant's, times the count: `get_cost` leaves `count` out of the price (live on 2026-10-15, `count` 2 quoted the same as 1), so the quote is asked with `count` left out (`HiggsfieldMCPProvider.estimate`, `serverEstimate`). The cost line counts every variant's billed seconds and jobs.
- **Answer.** Every `results[].id` is kept, duplicates and items without an ID skipped (`Generation.variantIDs`, `RemoteJob.variants`). One submit of N variants is one queued job until it is answered; then each further ID becomes a job of its own in the same batch (`Job.batchID`, assigned at enqueue), saved and polled before the job that sent the submit takes its own answer, so a crash in between can't lose a paid variant (`JobEngine.startVariants`). The request's price is shared evenly between the variants it asked for (`Cost.split`; whole credits split in whole credits that add up to the quote, a fractional quote evenly), so the jobs together count it once toward the daily cap. Each job then carries 1 variant, so a retry of one makes one. Queue and Library show the batch as "N variants" and Compare labels its cells "Variant 1"…
- **Fewer jobs than asked.** The jobs the answer names are tracked; the ones it didn't start count nothing, and the job that sent the submit says "Higgsfield started fewer variants than asked for: N missing" (`Job.missingVariants`). Nothing is resent: `generate_video` isn't idempotent, so a submit of variants is sent once like any other, and an unknown outcome fails the job without a resend.
- **Seen live (2026-10-15, issue #114).** `seedance_2_5` `t2v`, 4 s at 480p with `count: 2`, answered two `results[]` items (`id`, `type: "video"`, `status: "pending"`, `model`), each its own job ID (`generate_video_count_2.json`), and was charged per variant: two `transactions` entries of 12 credits against a `get_cost` quote of 12 for one. As assumed. Still unseen: how a request that starts only some of its variants is charged.

**Not done (issue #44): batch submit (`generate_video_batch`).** Submits stay one `generate_video` per job, decided on the catalog snapshot of 2026-10-15. The snapshot gives the tool as `{requests: [{index, params}]}` (1–12 items, `count` fixed to 1, no `get_cost`) answering `{jobs: [{index, job_id, status, error}], submitted_count, failed_count}`, with `idempotentHint: false`, and its description says a partial failure or timeout doesn't make the batch safe to retry. The issue's rule was to batch only if a resent batch is deduplicated: it isn't (no idempotency key), and how a batch that fails partway is charged is unknown, so a retry could pay twice. The per-job submit keeps each job's own refusal, unknown-outcome and retry handling, and `jobs_wait` already polls a batch in one call per tick (open question 4).

**Operations on a result (issue #41): on, checked against the catalog snapshot.** A result's page has an Enhance menu with Upscale…, Reframe…, Remove Background…, Dub… and Change Voice…. Each makes a job whose spec carries `JobSpec.operation` (the action and, for a result the signed-in account made, its job ID) and whose `parentID` is the result; it runs through the same engine path as `generate_video` (submit, `job_status`/`jobs_wait`, download) and lands in the Library linked to its parent. Every argument the app sends follows the `inputSchema`s of `docs/mcp-snapshots/2026-10-15.json` (`VideoEdit`, `VoiceList.swift`), and what it reads (`results[].id`, `error`, `cost`, and `job_status`'s `generation.results.rawUrl`) is in their `outputSchema`s, so `AccountModel.postOperationsConfirmed` is `true`. One switch covers all six tools. Tests check every call the stub server gets against the snapshot's schema (`CatalogSnapshot.violations(of:sentTo:)`).

Calls, per the snapshot (every tool takes one `params` object with `additionalProperties: false`, except `reframe`'s and `upscale_video`'s `oneOf`):

| Tool | Arguments Jutsu sends | What Jutsu reads |
|---|---|---|
| `upscale_video` | `params`: `video_id` (the parent's job ID or an upload's `media_id`); `provider: "bytedance"` with `resolution` `1080p`/`2k`/`4k`, the source's `width` and `height` (required) and `fps` 24/30/60; or `provider: "topaz"` with `resolution` `1080p`/`2160p` and nothing else | `results[].id` (read as `execute_preset`'s job ID, so `job_ids`/`jobs`/`job_id` work too), `request_id`, `cost.credits(_exact)` if present |
| `reframe` | `params`: `medias: [{role: "video", value: job ID or media_id}]`, `aspect_ratio` `9:16`/`1:1`/`16:9`; for a source over 15 s also `duration_seconds` and `resolution` (`480p`/`720p`/`1080p`, the parent's). Quote: `params: {get_cost: true, duration_seconds, resolution}` | Same; a quote from `cost.credits_exact` or `cost.credits` |
| `remove_background` | `params`: `media_id` (the job ID or an upload's `media_id`), `media_type: "video"` | Same |
| `dubbing` | `params`: `video_id`, `target_language`, one of the 18 ISO 639-3 codes in the schema's enum (`eng`, `cmn`, `fra`, `hin`, `ita`, `jpn`, `kor`, `por`, `rus`, `tur`, `spa`, `deu`, `ara`, `pol`, `ind`, `fil`, `swe`, `fin`) | Same |
| `voice_change` | `params`: `video_id`, `voice_id`, `voice_type` (`preset` or `element`, as `list_voices` named it) | Same |
| `list_voices` | `size: 100` (its maximum), `cursor` from the last page; at most 5 pages | `voices[]` (`voice_id`, `voice_type`, `name`, `preview_url`; `gender` and `logo_url` unused), `has_more`, `next_cursor`. Read once per connection |

- **Changed from the first guesses (#95).** Every call now wraps its arguments in `params`. `upscale_video` names the video `video_id` (not `job_id`/`media_id`), never sends a frame rate or size to Topaz, sends Topaz 4K as `2160p` and has no Topaz 2K; the standard upscaler needs the source's size, and a left-out `fps` means the server's 24 fps, not the source's rate, so "Keep" is no longer offered (stored jobs with it still decode and send no `fps`). `remove_background` names a job ID as `media_id` too, and has no `get_cost`.
- **Input.** A result the signed-in account made is named by its job ID and nothing is uploaded; every tool's schema says it takes "a confirmed uploaded media_id or a completed video job_id" under the same key. Any other result (made with an API key, or by another account) is uploaded with `media_upload` / `media_confirm`. A submit explicitly refused before execution while it named a job ID is sent once more with the file uploaded instead. Other execution errors (`isError` without `Invalid request:`) and internal JSON-RPC errors don't establish a refusal and never trigger that fallback.
- **Price.** There is no `get_cost` tool: a tool that quotes declares `get_cost` in its own `params`. Only `reframe` does, and it is priced by length and resolution alone, so it is quoted before anything is uploaded, whoever made the result, and asked only when the live schema still declares `get_cost`. `upscale_video` says it has no cost preflight; `remove_background`, `dubbing` and `voice_change` refuse unknown keys. Those are quoted through `generate_video` instead: the catalog lists each as a video model, and `{params: {model, get_cost: true, duration}}` with the result's whole seconds answers `cost.credits` without submitting anything (`VideoEdit.Operation.quoteModel`). Checked live on 2026-10-15, with a dub of 7.04 s billed 21 credits, the quote for 7 s, and again in the paid run of issue #114, where a 4.02 s clip's dub, voice change and background removal were quoted 12, 1 and 1 at 4 s and billed exactly that: `dubbing` 3 credits a second; `voice_change` about 0.1 a second, rounded up (60 s is 6, 61 s is 7); `video_background_remover` 1 at any length; `bytedance_video_upscale` by length, `resolution` and `fps`, which it takes although the schema doesn't list them (10 s: 2 at 1080p, 4 at 2k, 8 at 4k, 15 at 4k and 60 fps). `topaz_video` answers that it has no cost estimation (`job_type 'topaz_video' does not support alpha v2 cost estimation`), so a Topaz upscale shows "Price shown after the run" and asks the user to agree to an open price, as does any quote that fails or names no price ("Price unknown — charged on completion"); under a daily cap it also asks as any job of unknown price does (`SubmitDecision.budgeted`). A job of unknown price counts as 0 toward the cap and shows "Price unknown" until an answer prices it.
- **Topaz's charge after the run (issue #113).** When a job of unknown price completes, the engine asks the provider what it was charged (`GenerationProvider.charge(of:)`) and keeps the answer as the job's price, which the cap and Spending count from then on. For a Topaz upscale the account reads `transactions` (read-only), newest first, 50 at a time and at most 4 pages, until a page reaches back past the job's window: 2 minutes before the submit to 2 minutes after the job finished, for clock skew and for a charge booked at either end (`AccountCharges`). A transaction names no job, so the match is by name and time: an entry whose `display_name` contains "Topaz" (any case) and not "image". The window must hold exactly one such entry, and it must be a `spend` of a non-zero amount; none, two (upscales sent together), or a refund next to it leave the price unknown. The amount is the spend's absolute value, exact. Higgsfield's name for a Topaz charge hasn't been seen live, so a name without "Topaz" (say "Video Upscale") matches nothing and the price stays unknown; it is never guessed. The `display_name`s seen on 2026-10-15 (issue #114) were "Seedance 2.5", "Dubbing", "Voice Change", "Video Background Remover", "Higgsfield Soul V2", "GPT Image 2.0", "Grok Image 2.0" and "Higgsfield Genjutsu - Object Swap": still no Topaz.
- **Limits.** Reframe takes a result of at most 60 s (longer ones are refused before sending and the sheet says why). The schema also offers 4:3, 3:4 and 21:9 but not 4:5, so the sheet's presets are 9:16, 1:1 and 16:9.
- **Sheets.** Reframe draws the new canvas's dashed outline around the result's first frame (`ReframeCanvas`, from `ThumbnailCache`). Dub lists the 18 languages by their system names in the user's language (`Locale.localizedString(forLanguageCode:)`). Change Voice lists the voices with a play button for each `preview_url` (an `AVPlayer`, stopped when the sheet closes).
- **Output (seen live on 2026-10-15, issue #114, from a 4.02 s 480×854 clip).** Remove Background made an H.264 MP4 (yuv420p) of the source's size, 4.0 s long, with **no alpha and no audio**: the subject stays on a black background, nothing is transparent. The sheet says so, and the source's sound is put back after download as for a generation, cut to the result's length (`PostAction.restoresSourceSound`, `AudioPlan`), so the file is an MP4. Dub and Change Voice made H.264 + AAC MP4s of the source's size and length; their sound is the point, so it is kept as the server gave it. Upscale and Reframe weren't run: their file keeps the result URL's extension and the server's sound. Nothing is transcoded.
- **API key.** The menu is hidden, or says "Needs a Higgsfield account" on a result an account made. It has no Connect button: the app holds one connection, so signing in to the account from there would replace the key in Keychain and pause the key's queued jobs, which is a sign-out of the key.

Not seen live, and shown or handled as unknown: the price of a Topaz upscale before it runs (the sheet says "Price shown after the run") and the `display_name` of its charge in `transactions`, what Upscale and Reframe return, whether a resend after a lost answer starts a second paid job (no idempotency key exists, so a submit is never resent), whether the size the app sends `bytedance` (the result file's, probed) is the one it wants and whether `preset` (default `common`; `aigc` exists) should be set, and how long `list_voices`' `preview_url`s stay valid (the list is cached per connection).

**Reference images on the account (issue #42): on, checked against the catalog snapshot.** `AccountModel.imageGenerationConfirmed` is `true`, and Generate… runs on the account:

| Tool | Arguments Jutsu sends | What Jutsu reads |
|---|---|---|
| `models_explore` | `action: "list"`, `type: "image"`, `limit: 100`, up to 3 pages (`after` = the last page's `next_page_token`); `action: "get"`, `model_id` for the model of a request with images | `items[]`: `id`, `name`, `aspect_ratios`, and `medias: [{roles, max}]`; a model with no `aspect_ratios` (an animation or sprite model) isn't offered. Soul, Grok, Qwen, Nano Banana and GPT Image are offered first, at most 6 |
| `generate_image` | `{"params": {"model", "prompt", "count" 1–4, "aspect_ratio" (one of the model's own), "medias": [{"role", "value": media_id}], "use_unlim": false, "get_cost"}}` | `results[].id` (one job per image), `cost.credits_exact` or `cost.credits`, `error` |
| `job_status` | `jobId` | `generation.status` and `generation.results.rawUrl` (an object, as the `outputSchema` gives it) |

- **Image role, per model.** The snapshot's image list shows the role an image to edit goes in under differs by model: `image` for Soul 2 (at most 1) and GPT Image 2, `image_references` for Nano Banana, and none for Soul Cast. A request with images reads its model with `models_explore get`, sends them under the model's role, and refuses them before sending when the model takes none ("This model doesn't take an image.") or fewer ("This model takes at most N image(s)."). The model picker shows a model without a role as taking no image.
- **`use_unlim`.** Left out, the server can answer `unlim_choice` and submit nothing; it is always sent `false`, as for `generate_video`. **Refused on this plan:** on plan `ultra` (2026-10-15, issue #114), `soul_2` quoted with `use_unlim: true` (and an `adjustments` note capping `count` to 1), but the submit answered `isError` "Error starting generation: Unlimited generations aren't supported for text2image_soul_v2." and charged nothing (`generate_image_use_unlim_refused.json`). Such an answer is a refusal, not an unknown outcome (4.3).
- **Changed from the first guesses.** The role was always `image_references` and the ratios a fixed list; `job_status`'s results were also read as an array, which the schema doesn't allow.
- **Seen live (2026-10-15, issue #114).** `soul_2` with `count: 2` answered two `results[]` items, each its own job (`model: "text2image_soul_v2"`, `generate_image_count_2.json`), each charged 0.12 credits, the quote's `credits_exact` (`credits` rounds it up to 1). Still unseen: whether a resend after a lost answer pays twice (a submit is never resent). The image list in the snapshot is its first page only (`has_more: true`).

**The account's reference elements (issue #43): on.** References › From Higgsfield shows the Elements source on the account. An API key doesn't have it.

| Tool | Arguments Jutsu sends | What Jutsu reads |
|---|---|---|
| `show_reference_elements` | `action: "list"`, `size` 1–100, `cursor` (a number, the last page's `next_cursor`) | `items[]`: `id`, `name`, `category` (`character`, `environment`, `prop`; a `character_ip_verified` is read as `character`), `status` (only `completed` is usable; `ip_checking`, `nsfw` and the rest are left out), `medias: [{id, url, type}]` (`type` `media_input` or `image_job`); `next_cursor` |
| `show_reference_elements` | `action: "get"`, `element_id` (a UUID) | the one element under `items`, as above; its `error` if refused. A list item names only its first image, so `get` is asked whenever an element is picked |
| `show_reference_elements` | `action: "create"`, `category: "character"`, `name` (at most 32 characters; left out when empty), `medias: [{id, url, type: "media_input"}]` of confirmed uploads | the new element under `element`, as above; its `error` if refused |

- **Inputs.** An element image's `medias[].id` is an upload's `media_id` or an image job's ID; `generate_video`'s schema takes either in `medias[].value`, so a job of the same account sends the ID instead of uploading the file (`GenerationProvider.serverAsset`). A submit refused with a reason while it named such an ID is sent once more with the files uploaded.
- **Element ID or image ID (issue #110).** `manage_reference_elements` says to put an element in the prompt as `<<<element_id>>>` for `seedance_2_0`, `kling3_0` and Cinema Studio only, and never to put an element ID in `medias`. The account's models Jutsu runs (`hf_mult_*`, `seedance_2_5`, `kling3_0_motion_control`) aren't among them, so Jutsu sends neither the element ID nor its token: each of the element's images goes in `medias[].value` by its own media or job ID, as the schema allows for any image. Nothing changes until a model Jutsu runs is listed for the token.
- **Picking, cache and images.** The category filter runs on the loaded list. An element adds its images up to the mode's limit (`VideoModel.limits(for:hasSource:)`); with more images than fit, the user picks which. The images are downloaded once to `account-media/elements/<element>/`. One list is kept for the connection, loaded on first view and paged on demand, dropped on sign-out or a new sign-in.
- **Save to Higgsfield… (`create`).** A batch character's More menu publishes its images as a character element. Each image is prepared like a job's reference and uploaded with `media_upload` → PUT → `media_confirm` (`GenerationProvider.upload`), then `create` names the confirmed `media_id`s with their https upload URLs, as the tool asks. The element's ID is kept on the set in the Create draft, keyed by the set's files and the account, so the set shows "Saved to Higgsfield" and isn't published twice; the element goes first in References › From Higgsfield › Elements. A tool without `medias` in its schema reports the tool unavailable before anything is sent.
- **Free.** The snapshot names no price for `create`: it takes no `get_cost` or `max_credits`, its `outputSchema` has no cost, and the tool says it "returns synchronously", like a library edit. So Save to Higgsfield… asks for a name only, with no price confirmation. `idempotentHint: false`: a create is sent once, and a failure after it may have reached the server can still have made the element, which the list shows on its next load.
- **Status.** `create` may answer with an element still `processing` or `ip_checking`. It is offered at once, as Jutsu sends its images by their own media IDs; a reloaded list leaves it out until it is `completed`.

**Character sheets (issue #109): on, checked against live answers.** References › From Higgsfield › Characters lists the character sheets the app made on the signed-in account, newest first, then the account's own, and Create Character… makes new ones. The free calls were answered live on 2026-10-15; trimmed copies are in `docs/mcp-snapshots/live-2026-10-15/` and the tests replay them. A sheet is an AI Influencer image job: picking one adds it as a reference image named by its job ID (`generate_video` `medias[].value` takes "a job_id from a prior generation"), under the mode's image role (`image_references` for Genjutsu motion transfer). Soul characters and Soul training are not used: a Soul is a `soul_id` of the `soul_2` and `soul_cinematic` image models only, never a video reference. An API key has none of this.

| Tool | Arguments Jutsu sends | What Jutsu reads |
|---|---|---|
| `ai_influencer_get_options` | `tier` | `groups[]`: `id`, `label`, `max`, `options[]` (`id`, `label`, `tiers`); options of other tiers are left out. Live: 18 groups for `normal`, `max` 1 to 4; `tiers` lists tier IDs only; some options of `freak_face` carry a `slot` (`eyes`, `lips`, …), not used |
| `ai_influencer_list_presets` | `cursor` (a page number from 1), `size` 30 | `items[]`: `id`, `name`, `preview.thumbnail_url` (else `preview.url`), `recreate.params` (`tier`, `selection`, `brief`, `seed`), `recreate_unavailable_reason`; `cursor` is the next page's number (live: `2` after the first page). A page shorter than `size` is the last |
| `ai_influencer_prepare` | `tier` (left out when randomized without one), `selection` (`{group: [option IDs]}`, at most the group's `max`), `brief` ≤4,000 characters, `seed` 1–1,000,000 (a preset's), `batch_size` 1–4, `medias` (the face, ≤1) and `item_medias` (style references, ≤3), each `{role: "image", data: {id, type: "media_input"}}`, `randomize` | `params` (kept as sent back), `credits` (live: 1.125 for one sheet, 4.5 for four), `free_gens_remaining` when given (the live answer had none); `submitted` is `false` |
| `ai_influencer_generate` | `params` = the quote's `params` unchanged, `max_credits` = the quoted `credits` | `submitted`, `job_id`, `job_ids`, `credits`; with `submitted: false`, `error` |
| `assets_picker_list` | `source: "influencer"`, `kind: "image"` (required), `size`, `cursor` | as for uploads: `items[]` with `id`, `url`, `thumbnailUrl`, else left out; `next_cursor`. Live: `{items: [], next_cursor: null}` on an account without sheets |
| `jobs_wait`, then `job_status` | the sheets' job IDs, ≤12 per call | as for video jobs; the image under `results` |

- **Price and money.** The form is quoted with `ai_influencer_prepare` 0.4 s after each change; the sheet shows the quote as Higgsfield gives it ("1.125 credits · Price from Higgsfield"); the daily cap and Spending count it as quoted. Generate sends the quoted `params` once, capped at the quoted credits, never the form again (a randomized design differs each time it's prepared). The daily cap is checked first. The price goes into `ImageSpendLog` (`purpose: characterSheets`) when the submit is sent, is taken off when Higgsfield refuses it (`submitted: false` or an error before sending) or every sheet fails, and is kept when the answer is lost: the run then says the sheets may have started, and nothing is resent. A second click while a submit is out sends nothing.
- **Every job is kept.** Each ID of `job_ids` (else `job_id`) goes into `character-sheets.json` before anything else, with the account it belongs to, and is polled with backoff until it ends, after a relaunch or a reconnect too. A finished sheet is saved to Library › Images and listed in Characters from its saved copy.
- **The account's list** (`characterSheetListConfirmed`, on): the call is confirmed live, its items aren't, as the account had none. An item with the usual picker fields is listed after the sheets made in the app and named by its `id`; one without them is left out. If that `id` turns out not to be the sheet's job ID, a sheet made in the app can show twice.
- **Tier titles.** The schema and the live `get_options` answer give tier IDs only; Jutsu shows `normal`, `freak` and `total` as Natural, Bold and Wild, and the animal tiers by their animal.
- **Left out:** free generations (`use_free_gens` is never sent), styles of other users, and recreating a preset without the form.

**Virality scores in batch comparison (issues #45, #111): on** since a live run on 2026-10-15 (issue #37). Score Variants… is shown on an account and hidden with an API key.

| Tool | Arguments Jutsu sends | Answer |
|---|---|---|
| `virality_predictor` | `{"action": "create", "params": {"model": "virality_predictor", "medias": [{"role": "video", "id": job ID}]}}` | `{job_id, model: "virality_predictor", poll_interval: 1.5}`, or `error` |
| `job_status` | `{jobId}` of that job, every `poll_interval` seconds (at most 10, 200 polls) | `generation: {id, type: "image", status, model: "brain_activity", params: {prompt, medias, video_meta, analysis, …}, results: {rawUrl}}` |

- **Readings.** `params.analysis` is `null` until the job completes. Then `analysis.scores` has `overall_score`, `viral_potential`, `hook_score` (the first 3 s, `score_details.hook_window_seconds: [0, 3]`), `brain_engagement` and `sustain` on 0–100, plus `peak_second`, `peak_frame_index` and `peak_score` (0–1). `analysis.summary` has an `overall_score` of its own that differs from `scores.overall_score` (39 against 46 in the live run); Jutsu reads `scores`. Also there: `regions[]` (`id`, `title`, `subtitle`, `mean_score`, `peak_score`, `peak_second`, `lower_better`, `values_by_frame[]`), `timeline` (`frame_count`, `time_seconds[]`, `duration_seconds`, `captions_by_frame[]`), `global_scores_by_frame[]` and `score_details` (`disclaimer`, `normalization`). `results.rawUrl` is an HTML dashboard.
- **Shown.** A 0–100 badge (`overall_score`) with a small line of `global_scores_by_frame` on each cell; clicking it lists viral potential, hook (0–3 s), engagement, sustain, the peak second, the line, the disclaimer and "Open dashboard". `regions` and captions aren't shown.
- **`jobs_wait`** reports the job as `{status: "completed", type: "image", model: "brain_activity", result_url}` without `params`, so only `job_status` gives the readings.
- **Price.** 0 credits: the balance was the same before the call and after the job completed. The sheet says "Free" and asks nothing about the daily cap; each run is still recorded in `image-spend.json` (`purpose: viralityScore`) at 0.
- **Left out:** `action: "preview"`, the per-region readings, and trimming long clips.

**Kling O3 video reference on the account: off** (`klingVideoReferenceConfirmed`). The snapshot now lists all 57 video models with a `get` of each, and none takes Kling O3's video reference (a new clip after one reference video, with a length). The Kling 3.0 Omni models are `kling_o3_image_reference` (role `image_references` only; `mode` std/pro/4k, `duration` 3–15, `sound`, `multi_shots`), `kling_o3_flf` (`start_image`, `end_image`) and `kling_video_edit` ("Edit a source video with text instructions and optional reference images": roles `video_references` and `image_references`, `mode` std/pro/4k, no `duration`). `kling_video_edit` is the REST `video-edit`, so it runs Kling O3 Edit; the video reference keeps no account model and runs with an API key only.

**Account models of issue #101** (`models.json` `request.account`), each confirmed by its `models_explore get` in the snapshot for every field sent (`MoreVideoModels` checks each request against it):
- `kling_video_edit` (Kling O3 Edit, Edit mode): the source as `video_references`, images as `image_references`, `mode` `std` or `pro`. No `duration` or `resolution`.
- `wan3_0` and `wan3_0_prime` (Wan 3.0 and 3.0 Prime, Motion mode): `video_references` and `image_references`, `duration` 2–30 (the schema's `min` is −1, "let the model choose", which isn't sent), `resolution` 480p/720p/1080p, `generate_audio`. No `mode`; `enable_thinking` and `aspect_ratio` aren't sent.
- `cinematic_studio_video_4_0` (Cinema Studio 4.0, Motion mode): Seedance's parameters, sent as for a Seedance job with a source: `mode` `omni_reference`, `duration` 4–30, `resolution` 480p or 720p (the REST list; the account also has 1080p), `generate_audio`. The creative controls aren't sent (`ModelParameter.cinemaControls` is REST only): the account names them `era_id`, `camera_model_id`, `camera_lens_id`, `camera_aperture_id`, `pacing_id`, `genre_id`, `light` + `light_id` and `color_palette`, "creative-control id"s that the snapshot doesn't list and that may not be the REST values; it has no camera movement. Create disables the Direction row on the account and says why.
- `minimax_h3` (MiniMax H3) and `minimax_h3_max` (MiniMax H3 Max), Motion mode: the source as `video_references`, images as `image_references`, `resolution` (`2K` for H3; `480p` or `768p` for Max, default `768p`) and `duration` (H3 4–15, Max 5–15; `models.json` keeps REST's 5–15 until the account's limits are cached). No `mode`, `generate_audio` or `aspect_ratio` (the default `auto`), as for Wan (shape `wanReference`). Max has no REST endpoint, so it is offered on the account only. Fallback rates from free `get_cost` quotes of 2026-10-28: H3 2 credits a second at 2K, H3 Max 2.5 at 768p; H3 Max at 480p has none, so until Higgsfield quotes such a job (before upload, as it is sent a length) its price is unknown.
- Not on the account: Wan 2.7 (`wan2_7`'s roles are `start_image`, `end_image` and `audio_references`, no reference video), Kling 2.6 Motion Control (`kling2_6` is image-to-video from a `start_image`).
- Priced by `get_cost` like every account model (4.5, Price before upload). Wan 3.0, Wan 3.0 Prime, Cinema Studio 4.0 and MiniMax H3 and H3 Max are sent a length and quoted before upload; Kling O3 Edit follows its source and is quoted after upload. The fallback rates in `models.json` are the free quotes of 2026-10-15, and MiniMax's of 2026-10-28.

**Linked files on the account (issue #90): `media_import_url`.** A file downloaded from a pasted link, used whole and as downloaded, is imported by its link instead of uploaded: `{"url": <HTTPS link>, "type": "video" | "image"}` answers `{media_id, type, content_type, source_url, warning, error}`, and the job sends the `media_id` (`HiggsfieldMCPProvider.linkedAsset`, `HiggsfieldAccount.importMedia`). Only HTTPS links of at most 50 MB (the tool's limit) are imported; a larger file, a refusal (`error` or no `media_id`) or a missing tool uploads the file as before. Confirmed live on 2026-10-15 (issue #114): a public 1 MB MP4 answered `{media_id, type: "video", content_type: "video/mp4", source_url}` (`media_import_url.json`).

### 4.5 `generate_video`

Status: arguments checked against the catalog snapshot `docs/mcp-snapshots/2026-10-15.json` (`tools/list` and `models_explore get` of each mapped model). Jutsu builds the arguments in `VideoRequest.arguments` (`Packages/HiggsfieldKit/Sources/HiggsfieldMCP/VideoRequest.swift`) from a `JobSpec` (`AccountModel.request`):

```json
{
  "params": {
    "model": "seedance_2_5",
    "mode": "omni_reference",
    "medias": [
      { "role": "video_references", "value": "<media_id>" },
      { "role": "image_references", "value": "<media_id>" }
    ],
    "prompt": "…",
    "resolution": "720p",
    "duration": 8,
    "generate_audio": false,
    "aspect_ratio": "16:9",
    "get_cost": true,
    "use_unlim": false
  }
}
```

| Jutsu model | MCP `model` | Fields |
|---|---|---|
| Genjutsu Motion Transfer | `hf_mult_motion_control` | `medias`, `prompt`, `resolution` (`480p`/`720p`/`1080p`, default `720p`) |
| Genjutsu Object Swap | `hf_mult_replace_object` | `medias`, `prompt`, `resolution` |
| Genjutsu Lite Motion Transfer (issue #15) | `hf_mult_motion_control_flash` | as Genjutsu's; Wan 3.0, up to 15 s (`models.json` keeps 4–15 s until the account's limits are cached) |
| Genjutsu Lite Object Swap | `hf_mult_replace_object_flash` | as Genjutsu's |
| Seedance 2.5 | `seedance_2_5` | `mode`: `t2v` (no media), `omni_reference` (references, and start/end frames), `video_edit` (Edit), `video_extension` (Extend, with `extension_mode: "forward"`); `duration` 4–30 (default 5; not sent for Edit); `resolution`; `generate_audio` (server default `true`; Jutsu sends it always: without a source and for Extend unless muted, with a source only for the Audio option Generated, issue #23); `bitrate_mode` `standard`/`high` (server default `standard`; sent only when picked); `aspect_ratio` (for a clip without a reference video: `16:9`, `9:16`, `auto`, …; for frames the start frame's nearest ratio) |
| Kling 3.0 Motion Control | `kling3_0_motion_control` | `mode` `std` or `pro` (Jutsu sends `pro` for 1080p); `duration` (not listed by `get`; the schema says an unsupported one is clamped); exactly one image; `background_source: "input_video"` keeps the video's background (default `input_image`). `models_explore get` lists no other parameter |
| Genjutsu Restyle | — | Runs through `execute_preset` with a `genjutsu-style:` ID |

Rules Jutsu depends on:

- **Media roles** are `video_references` and `image_references`, and Seedance's frames `start_image` and `end_image`, as each model's `medias[].roles` lists them (Seedance 2.5 also takes `audio_references`, unused). The server also accepts `video` and `image` and renames them.
- **Optional fields:** empty `medias` and `prompt` are left out, and so are unset optional fields.
- **Cost:** `get_cost: true` quotes the exact credits and charges nothing. The same params without it submit. Per the `outputSchema`, `cost` comes only with `get_cost`, never in a submit's answer.
- **`count`** (confirmed: an integer 1–4 inside `params`, default 1) is `JobSpec.variants`, sent only above 1 and never with `use_unlim` (4.4, issue #44).
- **`use_unlim`** (confirmed: a boolean inside `params`, on `generate_video` and on each `generate_video_batch` item) is always sent. Left out, the server submits nothing for a model the allowance covers and answers `unlim_choice` (`message`, `model`, `remaining`, `expires_at`), a question for the user. `true` also caps `count` to 1, and "a rejected opt-in is reported rather than quietly replaced with a charge". Jutsu sends `true` only when the user turned on Settings › Connection › Unlimited generations (off by default) and `models_explore` said both that the model supports it and that the account has an allowance now (`UnlimitedAllowance`, issue #22); otherwise `false`, paid in credits. **Refused on this plan** (`ultra`, 2026-10-15, issue #114): `get_cost` with `use_unlim: true` on `seedance_2_5` answered `isError` "Error estimating cost: Unlimited generations aren't supported for seedance_2_5.", and a `soul_2` submit with it was refused before execution with "Error starting generation: Unlimited generations aren't supported …" (nothing charged). `models_explore` lists `supports_unlim` for neither, so Jutsu sends `false` for both; a submit refused that way is a validation error, not an unknown outcome (4.3). The app reads `models_explore {action: "list", type: "video", limit: 100}` (up to 5 pages, until every account model of `models.json` was seen, `AccountModel.accountModels`) when it loads the capabilities, and again with the balance after each job while there is an allowance. Shapes confirmed by the snapshot:
  - a list page is `{items, has_more, next_page_token, unlim}`; the next page is asked with `after: <next_page_token>` (a string, `"20"` after the first 20 items); `limit` is 1–100, default 20. The first guess (`cursor` / `next_cursor`, #80, #92, #93) read only the first page, which holds none of the app's four models;
  - items name the model in `id` and carry `supports_unlim: true` only for a model that takes the allowance (in the snapshot: `kling3_0_motion_control`, `seedance_2_0`, `seedance_2_0_mini`; not `seedance_2_5` or Genjutsu). `get` answers carry the same flag;
  - the top-level `unlim` (and each `get` answer's) is `{available, expires_at, remaining}`; `remaining: null` means unmetered, so it no longer reads as "no". The snapshot's account had `available: false`. A trailing text block lists "Unlim configs" the allowance covers; Jutsu doesn't read it;
  - other keys (`models`/`data`, `model_id`/`model`, flags `can_use`/`enabled`/`active`/`eligible`, count `left`) are still read; anything else counts as "no";
  - a submit's answer that named credits would still clear the job's unlimited flag (`HiggsfieldMCPProvider.unlimitedCharge`), but per the schema it never does.
- **Preset notice:** the server may answer with `notice.type: preset_recommendation` and `notice.data.retry_literal_with.declined_preset_id`. Only when that answer contains neither `results` nor `cost` does Jutsu resend with `declined_preset_id` so the prompt is used as written. An accepted job is kept without resending, even if the answer also includes a notice. A notice still alone after the retry is shown as a validation error.
- **Limits:** the constants in `VideoModel.limits(for:hasSource:constraints:)`, overridden bound by bound by what `models_explore` says (below):
  - Seedance's 4–30 s comes from `get_cost` answers and `models_explore get`.
  - Kling's single image comes from the server's refusal "exactly one image_references entry is required".
  - Genjutsu's limits come from the REST docs.
- **Price before upload (issue #113).** The server's quote is the price; the catalog's rates are only a fallback. `HiggsfieldMCPProvider.estimate`, which Create asks 0.4 s after the form stops changing (`EstimateCache.estimate(_:after:)`) and the engine asks when it queues a job, works by model type:
  - **Sent a length** (Seedance from a prompt, frames or Extend; Kling 3.0 Motion Control, whose quote requires `duration`, #112; Wan 3.0 and 3.0 Prime; Cinema Studio 4.0): `get_cost` with the job's request minus `medias`, `prompt` and `count` (`AccountModel.quoteRequest`), before anything is uploaded. Live on 2026-10-15 these are priced by `duration` and `resolution` or Kling's `mode` alone; a Seedance job with a source is quoted as `t2v` at the same length. The quote is kept per model, `mode`, resolution, `duration` and `generate_audio` for the connection, and a second estimate while one is out waits for it (`HiggsfieldMCPProvider.quote`); a failed quote isn't kept. Create shows it as "Price from Higgsfield".
  - **Billed by the source** (Genjutsu Motion Transfer and Object Swap, Seedance Edit, Kling O3 Edit): a quote without the source in `medias` gets 422, so before upload Create shows the fallback estimate ("Estimate, Higgsfield quotes it after upload"), and the engine quotes the uploaded files right before submit (`serverEstimate`), asking again under a daily cap when that quote is higher.
  - **Genjutsu Style:** `get_presets` with `preset_id` and `initial_inputs {video, resolution}` answers `cost_credits` only in the TOON text (`PresetQuote.credits`); it needs the uploaded video, so before upload the fallback `styleCredits` (1.5 + 3, 7 or 11 a second; 12 s: 37.5, 85.5, 133.5, matching the live quotes).
  - **Fallback rates** (`models.json` `credits`, with a `modes` override for a mode priced apart; `AccountModel.estimatedCredits`), from the free quotes of 2026-10-15, per second at 480p / 720p / 1080p: Genjutsu Motion 3 / 7 / 20, Object Swap 3.25 / 7.58 / 21.66 (12 s: 39 / 91 / 260); Seedance 3 / 7 / 16, Edit 3.58 / 7.58 / 20.08 (12 s: 43 / 91 / 241); Kling 3.0 2.5 + 1.5 a second Standard, 2.5 + 2.5 Pro (the quotes round 20.5 and 47.5 down, the estimate up); Kling O3 Edit 1.5 Standard, 2 Pro; Wan 3.0 1 / 1.75 / 3.5; Wan 3.0 Prime 1.5 / 3 / 6; Cinema Studio 4.0 3 / 7; from the quotes of 2026-10-28, MiniMax H3 2 at 2K and H3 Max 2.5 at 768p (none at 480p). Used when a model can't be quoted yet or the quote fails; without a rate the price is "Price unknown". `models_explore` states no rates.
  - A quote is kept exact (an image can cost 0.5 credits), is multiplied by the variants, and is what the job is queued with (`Job.cost`, not an estimate), so the daily cap and Spending count it.
- **Not used:** `width`/`height`, `folder_id`, `preset_id`, `use_free_gens`, `context`. Seedance 2.5's `draft` and `draft_job_id` are used for its native draft (below, issue #115).

**Model limits from `models_explore` (issue #46).** On connect, and again when the cached answer is a day old (checked when Create loads the capabilities, never on a form edit), the account calls `models_explore {action: "get", model_id}` for each account model of `models.json` (`AccountModel.accountModels`, `HiggsfieldAccount.modelLimits(of:)`). The answers are reduced to `ModelConstraints` and cached per account in `Application Support/Jutsu Studio/cache/model-constraints.json` (`ModelConstraintCache`; Debug has its own container). Create's limits, validation, the request's `duration` and the estimate's billed seconds read that table; a missing, unreadable or other-version cache means the constants. Debug builds log where the table differs from the constants. Each answer maps to one job: `hf_mult_motion_control` → Genjutsu Motion Transfer, `hf_mult_replace_object` → Object Swap, `hf_mult_motion_control_flash` and `hf_mult_replace_object_flash` → Genjutsu Lite's, `seedance_2_5`, `kling3_0_motion_control`, `wan3_0`, `wan3_0_prime`, `cinematic_studio_video_4_0`, `minimax_h3` and `minimax_h3_max` → their Motion jobs, `kling_video_edit` → Kling O3 Edit (Seedance's Edit and Extend keep their constants). Wan 3.0's `duration` minimum of −1 ("the model chooses") isn't a length, so the catalog's 2 s stays.

The snapshot confirms the answer's shape: the model itself (no wrapper), `parameters` an array of `{name, type, description, default, options, min, max, required: "optional", nullable}`, and `medias` an array of `{name, type, roles}` without counts. So only Seedance 2.5's `duration` (4–30) is stated; Genjutsu and Kling 3.0 Motion Control state no duration, and no model counts its reference images, so those bounds keep the constants. List items carry `duration_range {min, max}` or `durations [...]` instead, but the app reads only `get`. Other shapes are still read, and anything else reads as "not stated":

- the model under `model` or `data`;
- parameters as an object by name or its JSON-schema `properties`;
- `duration`'s range from `minimum`/`maximum`, else from an `enum`/`values` of whole numbers without gaps (`[5, 10]` is no range and is ignored);
- reference images from a `medias` (or `media`) entry with `role` `image_references`/`image` (or, without roles, `type: "image"`), counted by `min`/`min_count`/`minItems`/`minimum` and `max`/`max_count`/`maxItems`/`maximum`;
- non-numbers, negative or fractional counts, lengths of 0 s or less, and a minimum above the maximum are ignored.

Excerpt of the `seedance_2_5` answer (snapshot; `description`s cut):

```json
{
  "id": "seedance_2_5",
  "medias": [{ "name": "medias", "type": "image", "roles": ["start_image", "end_image", "image_references", "video_references", "audio_references"] }],
  "parameters": [
    { "name": "mode", "type": "string", "default": "t2v", "options": ["t2v", "omni_reference", "video_edit", "video_extension"] },
    { "name": "duration", "type": "number", "default": 5, "min": 4, "max": 30 },
    { "name": "bitrate_mode", "type": "string", "default": "standard", "options": ["standard", "high"] },
    { "name": "extension_mode", "type": "string", "nullable": true, "options": ["backward", "forward"] }
  ],
  "unlim": { "available": false, "expires_at": null, "remaining": null }
}
```

With an API key nothing is fetched: the limits stay constants and USD prices stay in `pricing.json`, since the public catalog (`dash.higgsfield.ai/api/v2/catalog-models`) only lists "from" prices per family (issue #81).

**Seedance Edit and Extend on the account (issue #39): enabled.** `AccountModel.seedanceVideoOperationsConfirmed` is `true`. `models_explore get` of `seedance_2_5` names the modes: `video_edit` "to edit one reference video (billed by that video's duration; 'duration' and 'aspect_ratio' are ignored)" and `video_extension` "to extend a reference video ('aspect_ratio' is ignored — the output follows the extended video)", plus `extension_mode` (`backward`/`forward`), "required for mode 'video_extension' and not allowed otherwise". Jutsu sends:

- Edit: `mode: "video_edit"`, the clip as `video_references` (images as `image_references`), `prompt`, `resolution`, `generate_audio` (`false` unless the Audio option is Generated), no `duration` or `aspect_ratio`;
- Extend: `mode: "video_extension"`, `extension_mode: "forward"`, the clip as `video_references`, `duration` = the added seconds (4–30), `generate_audio` (unless muted), no `aspect_ratio`.

The first guess (#89) sent `video_extend` and no `extension_mode`. Free quotes of 2026-10-15: Extend 3 / 7 / 16 credits a second like `t2v`, Edit by the clip's length (12 s: 43 / 91 / 241). Seen live on 2026-10-15 (issue #114), from a 4.02 s 480×854 source at 480p:

- **Extend** (`forward`, `duration: 4`): the output is 4.00 s and holds only the new part; its first frame equals the source's last frame. Billed 12 credits (4 s × 3): the source's seconds aren't billed, so on the account Create's cost and trim lines count only the added seconds (`Pricing.billedSeconds(for:on:)`). The result is shown as what it is, the new part, and Library's "Join with Original…" puts the source selection in front of it with the source's sound (`ClipJoiner`), leaving out the new part's first frame and the same length of its sound, so the seam frame shows once and each part's sound stays under its picture (issue #134). REST's `video-extend` page says only "Requested output duration in seconds", so REST is treated alike until a run shows otherwise.
- **Edit** (`generate_audio: false`, no `aspect_ratio`): the job's params read `aspect_ratio` 16:9, 854×480 and `duration` 5, but the file is 480×854 and 3.71 s, shorter than its source, with no audio stream. Billed 15 credits (5 s × 3), as quoted: a 4.02 s source billed 5 s, so Edit bills at least 5 s (or the source's seconds rounded up; this run can't tell the two apart). The params' size and length aren't used: the source's sound is put back cut to the length read from the file (`AudioPlan`), with no padding, and operations probe the result file.

**Seedance's native draft on the account (issue #115).** `models_explore get` of `seedance_2_5` (catalog snapshot of 2026-10-15) lists `draft` (bool, default `false`, "Generate a 480p draft that can be finalized within seven days") and `draft_job_id` (string, nullable, "Completed draft job to finalize at 1080p"). The job's `params` echo both, in `show_generations`/`show_generation_by_ids` too, and `job_status`'s `outputSchema` names `draft`/`draftJobId`. The owner's paid run of 2026-10-15 (plan `ultra`):

- **Draft:** `{model: "seedance_2_5", mode: "omni_reference", prompt, duration: 15, resolution: "480p", aspect_ratio: "9:16", draft: true, use_unlim: false, medias: [7 × image_references], declined_preset_id}` quoted 45, exactly as the same request with `draft: false`, and was charged 45 ("Seedance 2.5" in `transactions`). The result is a normal 480×854 MP4 of 15.04 s with audio; its params say `draft: true, resolution: 480p`. The first quote answered only a `preset_recommendation` notice; declining it with `declined_preset_id` gave the cost, as the client does for every `generate_video` quote and submit (Preset notice, above).
- **Finalize quote:** `{model: "seedance_2_5", draft_job_id: "<draft job>", resolution: "1080p", get_cost: true}` quoted 80 credits, against 240 for a plain 1080p 15 s Seedance: a third, 16 → about 5.33 credits a second. With `mode`, `prompt`, `duration` and `aspect_ratio` beside `draft_job_id` it quoted 240, so extra parameters make it a fresh render.
- **Finalize submit:** not run. The owner accepted the request on the strength of the 80-credit quote, without a live finalize, so it is on like any other confirmed call; its answer and output are read as any `generate_video` job's.

What Jutsu sends:

- **Draft** (`AccountModel.sendsNativeDraft`): Draft of a Seedance 2.5 generation at 480p (a prompt alone, references or frames) adds `draft: true` to the request it sends anyway, quote included; nothing else changes, so the price is the 480p rate. Edit and Extend, and a draft at 720p or 1080p (Settings › Output › Draft resolution), stay plain renders. The submit marks the job, and each variant, as a native draft (`RemoteJob.isNativeDraft`, stored with the job).
- **Finalize in 1080p** (`VideoRequest.finalize(draftJobID:)`, `JobSpec.draftJobID`): on a native draft the signed-in account made, for seven days after Higgsfield completed it (`Job.chargedAt`, else when the job finished; `Job.finalizeDeadline`), its 1080p final, single (Render final) or for a batch's starred drafts, is `{model: "seedance_2_5", draft_job_id: <the draft's job ID>, resolution: "1080p", use_unlim: false}` and nothing else: no `count`, `medias`, `prompt` or length. The final keeps the draft's inputs for the library, uploads nothing and is the draft's child (`Job.parentID`). 720p, an expired draft, another account's draft and an API key render the inputs again as before; REST is unchanged.
- **Price:** the finalize is quoted live with the same four keys and `get_cost: true`, cached per draft (`QuoteKey.draftJobID`). When the quote fails the estimate is a third of the 1080p fallback rate for the draft's length (`AccountModel.finalizeShare`, from the quotes above), marked as an estimate.
- **Shown:** the draft's page says until when it can be finalized (or that the window ended) and opens on 1080p, whose button reads Finalize in 1080p; a card's menu offers Finalize in 1080p… instead of Render Final… while the window lasts.
- **History:** a `seedance_2_5` job whose `show_generations` params say `draft: true` is imported as a native draft (`PastGeneration.isDraft`, `HistoryItem.isNativeDraft`), and its seven days count from the item's `createdAt`, the time the import already charges it at. Until it is downloaded it offers only Edit Inputs; once in the library it offers Finalize in 1080p like a draft made in the app. A job with `draft_job_id` set is imported as a final keeping that ID (`JobSpec.draftJobID`); the import links no parents, so it isn't attached to its draft in the chain.

**Model parameters on the account (issue #40).** `generate_audio` with a source uses the confirmed key, so the Audio option Generated works on both connections. The others have a switch each in `AccountModel`; while one is off, the account's capabilities leave the parameter out (`Capabilities.parameters`), Create disables its control with the reason, and a job from frames is refused before any call.

1. **Seedance `bitrate_mode`: on** (`seedanceBitrateConfirmed`). Key and values match REST (`standard`/`high`), but the defaults differ: `standard` on the account, `high` on REST. Create sends a bitrate only once the user picks one; until then the picker shows each connection's own default (`CreateForm.bitrate(on:)`) and the server applies it.
2. **Seedance start and end frames: on** (`seedanceFramesConfirmed`). `seedance_2_5` has no image-to-video mode, but its `medias` roles include `start_image` and `end_image`, and the server's other Seedance 2.5 tool, `scene_builder_3d_generate_video`, puts "medias with image/start_image/end_image/video/audio roles" under `omni_reference` (and refuses a `start_image` with a "non-omni mode"). So Jutsu sends `mode: "omni_reference"` with the images as `start_image` and `end_image`, and the start frame's `aspect_ratio`: sent none on 2026-10-15 (issue #114), two 480×854 frames made an 854×480 clip, the server's 16:9 default. The engine reads the start frame's upright size when the job is queued and sets the nearest of the model's ratios (`AspectRatio.nearest(to:)`, `JobEngine.insert`); REST's `image-to-video` derives it itself and is sent none. Create hides the Frame picker for frames, as the clip takes the start frame's shape. The first guess (#91) sent `mode: "i2v"`. Create still needs a start frame; whether the server takes an end frame alone needs a live run. A start frame quotes like `t2v` (free quotes of 2026-10-15).
3. **Kling `keep_original_sound` and `character_orientation`: not offered by the account.** `models_explore get` of `kling3_0_motion_control` lists only `mode` and `background_source`, so there is no switch and no account mapping: both run with an API key only, Create's controls say "… only with an API key, not on the account", and the account's Kling sound is handled after download as before.

Kling 3.0 Motion Control has only `std` and `pro`, so Create offers Standard and Pro only. Other `generate_video` models are in Appendix B.

### 4.6 Paid run of 2026-10-15 (issue #114)

The owner ran issue #114's checklist on the account (plan `ultra`) from a 4.02 s 480×854 clip, at 480p on `seedance_2_5`. Trimmed answers are in `docs/mcp-snapshots/live-2026-10-15/` and the tests replay them (`LivePaidRunTests`).

- [x] **Variants (#107):** `generate_video` `count: 2` answered two `results[]`, each its own job, charged per variant: two `transactions` entries of 12 against a quote of 12 for one (4.4, Variants).
- [x] **Image generation:** `generate_image` `count: 2` on `soul_2` answered two jobs, each charged 0.12 (4.4, Reference images).
- [x] **Seedance Edit and Extend on the account:** Extend returns only the new part (4.00 s, its first frame the source's last), billed 12 for 4 s, the source's seconds not billed. Edit's file is 480×854 and 3.71 s without audio although its params say 16:9, 854×480 and 5 s; billed 15 (5 s × 3, as quoted) (4.5, Edit and Extend). Since issue #134 every downloaded result, imported from `show_generations` or made in the app, has its length and size read from the file (`Job.outputMedia`), and "Join with Original…" shows the seam frame once.
- [x] **Seedance start and end frame** through `mode: omni_reference`: runs, but without `aspect_ratio` two 480×854 frames made an 854×480 clip. Jutsu now sends the start frame's ratio (4.5, Model parameters).
- [x] **`use_unlim`:** refused on this plan. `get_cost` on `seedance_2_5` and a `soul_2` submit both answered "Unlimited generations aren't supported", nothing charged; the refusal is classified as such (4.3, 4.5).
- [x] **`jobs_wait`** with ten running jobs: the `outputSchema`'s shape, `in_progress` while running, `poll_after_seconds: 10`, held about 15 s; `type` says `image` for a running Seedance job (4.4, Polling).
- [x] **`media_import_url`** for a public 1 MB MP4: `{media_id, type, content_type, source_url}` (4.4, Linked files).
- [x] **Post-operations:** Remove Background is an H.264 MP4 without alpha or audio, the subject on black; Dub and Change Voice are H.264 + AAC MP4s of the source's size and length (4.4, Operations).

---

## 5. REST and MCP differences

| Topic | REST | MCP |
|---|---|---|
| Model choice | Endpoint path per model and operation (`…/std` vs `…/pro`) | `model` + `mode` inside `params` |
| Media | Public HTTPS URLs in named fields (`video_url`, `image_urls`) | Confirmed `media_id`s in `medias[{role, value}]` |
| Price | `POST /estimate/{endpoint}` → USD and credits | `get_cost: true` → credits |
| Idempotency | `Idempotency-Key` header | None documented; Jutsu doesn't retry an MCP submit whose outcome is unknown (`submitIsIdempotent == false`) |
| Cancel | `POST /requests/{id}/cancel` while queued | No cancel tool known |
| Moderation | `nsfw` | `nsfw`, and `ip_detected` (Seedance family; the web app's `reveal_generation` can release it) |
| Kling background | Not available | `background_source: "input_video"` |
| Kling sound and orientation | `keep_original_sound`, `character_orientation` (sent since issue #40) | Not offered by the account's model; sound handled after download |
| Seedance bitrate default | `high` | `standard` |
| Seedance frames | `image-to-video` endpoint; the frame follows the start image | `omni_reference` with `start_image` / `end_image` roles and the start frame's `aspect_ratio` (left out, 16:9) |
| Seedance Extend | The output's length is `duration`; the docs don't say whether it holds the source, so it is taken as the new part | The new part only (seen live); only the added seconds are billed |
| Unlimited plans | N/A | `use_unlim`, opt-in where `models_explore` reports `supports_unlim` and an `unlim` allowance; MCP help says unlimited doesn't apply (issue #22) |
| Account data | None | Balance, history, likes, transactions, uploads, galleries |
| Retention | 7 days after the request finishes by default, shorter with an account retention or `Hf-Expires-After` (3.12) | Results stay in the account's history |

## 6. Open questions

1. Answered (issue #114): `jobs_wait` and `generate_video` with `count` were seen live on 2026-10-15 and match their `outputSchema`s (4.4).
2. Whether Seedance takes an end frame alone on the account (issue #40). Whether a Seedance job with a reference video is billed only by its `duration`, as the quote before upload assumes; the quote of the uploaded files before submit is exact either way (issue #113).
3. Genjutsu Style results in the account's history (issue #21): a live Style job is `model: "restyle"`, `type: "image"` while queued or in progress and `"video"` once completed, with the bare preset UUID in `params.preset_id`; but neither `show_generations` (with any `type`, or `only_completed: false`) nor `show_marketing_studio_generations` lists it. History matches `model == "restyle"` exactly, and Import says Styles made elsewhere aren't listed.
4. How `generate_video_batch` charges when it fails partway; it is not idempotent (`idempotentHint: false`) and has no idempotency key (issue #44).
5. Answered on the account (issue #114): Seedance Extend returns only the new part. REST's docs don't say; REST is treated alike (4.5).
6. Whether the `<<<element_id>>>` prompt token, which the snapshot names for models Jutsu doesn't run, will reach Seedance, Kling or Genjutsu; Jutsu sends the elements' image IDs instead (issue #43, 4.4).
7. Whether resending `virality_predictor` for the same video starts a second job or returns the first; either is free (issue #111, 4.4).
8. Answered (issue #114): one job per `results[]` item, charged one by one. Still open: how a request that starts only some of its variants is charged (issue #44, 4.4).
9. The rate of a Topaz upscale and the `display_name` of its charge in `transactions` (the match needs "Topaz" in it; none was among the names seen on 2026-10-15), and what Upscale and Reframe return (issue #41, #113, 4.4). A background cut-out is an MP4 without alpha or audio (issue #114). The other operations are quoted through `generate_video` (4.4, Price).
10. The image models past the first `models_explore` page (issue #42, 4.4). `count` 2–4 answers one job per image (issue #114).
11. The Grok Image 2 default's price (1k medium isn't published), (issue #42, 3.13). Soul 2 bills per image on the account: 0.12 credits each (issue #114).
12. Character sheets (issue #109, 4.4): `ai_influencer_generate`'s answer, seen only as an `outputSchema`; the fields of an `assets_picker_list` `source: "influencer"` item and whether its `id` is the sheet's job ID (the live answer had no items); what an option's `slot` limits; whether a failed sheet is charged; and the tiers' display names, which `ai_influencer_get_options` gives as IDs only.
13. Whether the account will run Kling O3's video reference: the full catalog of 2026-10-15 has no model for it (4.4). Also the REST rates no page states per setting: Cinema Studio 4.0 per resolution, Kling O3 per `mode`, and Kling O3 Edit Pro (3.13). Only `/estimate` gives them.
14. Retention shorter than 7 days (3.12). Jutsu sends no `Hf-Expires-After`, but an account with a shorter account retention makes a download's `403` after `expires_at` a lost result, not an expired signed URL, while the download retries it for 7 days. Reading `expires_at` from the status would tell them apart.
15. A full queue's `429` hasn't been seen live (3.11): whether `Retry-After` and `retry_after_seconds` always agree, and whether a `503` `admission_control_unavailable` puts its `code` inside `detail`, as the `429` does, or next to it (Jutsu reads both).

## 7. Changelog

| Date | Change |
|---|---|
| 2026-10-28 | Reviewed against the docs changelog of 2026-10-23 and 2026-10-24. Queueing (3.11): submits above the concurrency limit are queued; only a full queue refuses one, with `429` `account_queue_full` and `Retry-After`, now `.concurrencyLimit(retryAfter:)`, waited out and sent again with the same key; `503` `admission_control_unavailable` is retried as a server fault; the `400` concurrency text parse is removed. Keys (3.1, 3.10): `403` `api_key_expired` and `api_key_disabled` map to `.unauthorized`. Documented, not used yet: data retention and `DELETE /requests/{id}` (3.12; the OpenAPI file has 9 paths), Standard Webhooks signing (3.9), Kling 4.0 (3.14). `platform.higgsfield.ai` is retired by 2026-10-31; Jutsu uses `api.higgsfield.ai` (3.1). Soul 2's `batch_size` is 1 or 4 (3.13). MCP protected-resource metadata lists only `clerk.higgsfield.ai` (4.2). The account's MiniMax H3 (2K) and H3 Max (768p) get fallback rates from free quotes: 2 and 2.5 credits a second. |
| 2026-10-21 | Issue #15: Genjutsu Lite (Wan 3.0) on the account as `hf_mult_motion_control_flash` and `hf_mult_replace_object_flash`, with Genjutsu's inputs, up to 15 s, priced by `get_cost` after upload (no fallback rate yet). Its REST endpoints `higgsfield/genjutsu-light/motion-transfer/v1.0` and `.../object-swap/v1.0` are priced in `pricing.json` ($0.05, $0.10 and $0.20 a second at 480p, 720p and 1080p) but have no published request schema (not in `llms.txt` or `openapi.json` on 2026-10-21), so an API key isn't offered Lite. |
| 2026-10-15 | Issue #115: Seedance's native draft on the account (4.5). Draft of a Seedance 2.5 generation at 480p sends `draft: true` (paid run: quoted and charged 45 for 15 s, as without it); Finalize in 1080p sends only `{model, draft_job_id, resolution: "1080p", use_unlim: false}` within seven days of the draft's completion, quoted live (80 credits for 15 s against 240 fresh, 2026-10-15), else estimated at a third of the 1080p rate. The finalize submit wasn't run live; the owner accepted it on that quote. A native draft imported from history (`draft: true` in its params) can be finalized too, its window counted from its `createdAt`; an imported finalize keeps its `draft_job_id`. |
| 2026-10-15 | Issue #134: `show_generations`' `width`, `height` and `duration` are a hint until the result is downloaded; then the file's own length and size (`Job.outputMedia`, read for app jobs too) are what Library, Compare, Enhance, Edit and Extend of the result use. "Join with Original…" leaves out the Extend result's first frame, the source's last, and the same length of its sound. |
| 2026-10-15 | Paid run of issue #114 (4.6): variants and image `count` confirmed, one job and one charge each; `jobs_wait`'s answer confirmed (`type` isn't read before a job ends); `media_import_url` confirmed. Fixed: a Seedance clip from frames now sends the start frame's `aspect_ratio` (sent none, it came out 16:9); a refused `use_unlim` ("Error starting generation: Unlimited generations aren't supported") is a refusal, not an unknown outcome; Remove Background is described as a black background without transparency and gets the source's sound back; the account's Extend cost line counts only the added seconds. Seen: Extend returns only the new part, Edit's params misstate its file and bill at least 5 s, Dub and Change Voice keep the source's size and length, `use_unlim` is refused on this plan. Trimmed answers in `docs/mcp-snapshots/live-2026-10-15/`. |
| 2026-10-15 | Issue #101 finished. MiniMax H3 reference-to-video over REST (3.13; `"2K"` only, 5–15 s, $0.13 a second from open.higgsfield.ai, at most five images) and on the account as `minimax_h3`; MiniMax H3 Max on the account only (`minimax_h3_max`, 480p or 768p), as the REST docs don't list it. `Resolution` gets 768p and 2K; a model without REST endpoints runs on the account only. Cinema Studio 4.0's creative controls (camera, lens, aperture, movement, genre, era, lighting, pacing, color palette) go in the REST body; the account's control IDs aren't in the snapshot, so they stay API key only (4.4). |
| 2026-10-15 | Save to Higgsfield… (issue #43, 4.4): a batch character set is uploaded with `media_upload` → PUT → `media_confirm` and published with `show_reference_elements` `create` (`category: "character"`, `medias` as `media_input`), checked against the snapshot's schema. Free: the tool names no price. The element ID is kept on the set so it isn't published twice. |
| 2026-10-15 | Issue #113 finished. REST: `/estimate` is the only price endpoint (3.8); a job with nothing to upload is quoted with it before upload, and the rest after upload as before. `pricing.json` gets Wan 3.0 and Wan 3.0 Prime per resolution from open.higgsfield.ai/pricing, and Cinema Studio 4.0, Kling O3 and Kling O3 Edit Standard as the top of their published range (`{"upTo": rate}`, shown as "up to"); Kling O3 Edit Pro stays unpriced (3.13). Account: a Topaz upscale shows "Price shown after the run", and its charge is read from `transactions` once it finishes, matched by name and time or left unknown (4.4, Price). |
| 2026-10-15 | From live runs (issues #111, #21): virality scores on (4.4): the free `virality_predictor` job is polled with `job_status` and its `params.analysis.scores` shown in batch comparison with the per-frame line, the disclaimer and the dashboard. Style jobs are matched in history by `model == "restyle"` (running ones are `type: "image"`), `execute_preset` read from `job_ids[0]`, and Import says Styles made outside the app aren't listed, as neither history tool returns them. |
| 2026-10-15 | Account video jobs show Higgsfield's price before upload (issue #113, 4.5 Price before upload): a model sent a length is quoted with `get_cost` and no media, debounced and kept per model, mode, resolution, length and sound; a model billed by its source shows the fallback estimate until its upload is quoted. Fallback credits updated to the free quotes of 2026-10-15 and added for Kling O3 Edit, Wan 3.0, Wan 3.0 Prime and Cinema Studio 4.0; Object Swap and Seedance Edit get their own rates. |
| 2026-10-15 | Character sheets checked against live answers of `ai_influencer_get_options`, `ai_influencer_list_presets`, `ai_influencer_prepare` and `assets_picker_list` `source: "influencer"` (4.4, `docs/mcp-snapshots/live-2026-10-15/`): fractional credits shown as given, `cursor` read as the next page's number with a short page ending the list, presets previewed by `thumbnail_url`, and the account's own list of sheets turned on. |
| 2026-10-15 | Character sheets replace Soul characters as References › From Higgsfield › Characters (issue #109, 4.4): Create Character… quotes with `ai_influencer_prepare` and submits the quoted `params` once with `ai_influencer_generate` and `max_credits`; every job ID is kept and polled; a sheet goes into a video job by its job ID. The account's own list (`assets_picker_list` `influencer`) stays off. `show_characters` and `soulCharactersConfirmed` removed. Element usage checked (issue #110): element image IDs, never element IDs or `<<<element_id>>>`, for the models Jutsu runs. |
| 2026-10-15 | Dub, Change Voice, Remove Background and ByteDance Upscale are priced before they run (4.4, Price): `generate_video` `get_cost` with the operation's catalog model and the result's whole seconds; a 7.04 s dub billed 21 credits matched the 7 s quote. Topaz stays unknown. |
| 2026-10-15 | Variants on the account (issue #44, 4.4): Create's Variants stepper sends `generate_video` `count` 2–4 (never with `use_unlim`), priced as one variant's quote times the count; every job the answer names becomes a job in one batch, sharing the request's price. Batch submit with `generate_video_batch` decided against: not idempotent, and a partial failure's charge is unknown. |
| 2026-10-15 | Issue #101: Kling O3 Edit, Kling 2.6 Motion Control, Wan 3.0, 3.0 Prime and 2.7 reference and Cinema Studio 4.0 (3.13, 3.14), with per-model resolutions and unpriced tariffs. On the account: `kling_video_edit`, `wan3_0`, `wan3_0_prime` and `cinematic_studio_video_4_0`, each request checked against its model's `models_explore get` in the snapshot. Kling O3's video reference stays off on the account: the full catalog has no model for it. `generate_video` model IDs are data (`VideoRequest.Model` is a struct), and the catalog export describes every listed video and image model. MiniMax H3 is left out (2K and 768p only). |
| 2026-10-15 | The account's switches reconciled with the catalog snapshot (4.4, issue #37). On: the operations on a result (#41), reference images (#42; image role and ratios per model, `use_unlim: false`, `job_status` results as an object) and reference elements (#43; `items`, `status`, `medias[].id`, `get` by `element_id`). Off, with what is unknown: Soul characters, virality scores (the call is now `params.medias`; the answer is only a job), Kling O3 on the account. Linked files on the account are imported with `media_import_url` (#90). Tests check every stubbed call against the snapshot's `inputSchema`. |
| 2026-10-15 | `generate_video`, `jobs_wait` and `models_explore` checked against the catalog snapshot (4.4, 4.5, issue #37): `jobs_wait` takes `jobs: [{job_id, index}]`; `models_explore` pages with `after`/`next_page_token` and `limit` ≤100 (only the first page was read before); an `unlim` block with `remaining: null` is unmetered; Seedance Edit (`video_edit`) and Extend (`video_extension` + `extension_mode`), `bitrate_mode` and start/end frames (`omni_reference`) turned on for the account; Kling's sound and orientation are API key only. `count`, `draft` and the batch tool recorded, not used. |
| 2026-10-15 | Reframe, Dub and Change Voice on a result (issue #41), and Upscale and Remove Background rebuilt, against the catalog snapshot `docs/mcp-snapshots/2026-10-15.json` (4.4): arguments in `params`, `video_id` for Upscale, Topaz 1080p/2160p only, a quote only from `reframe`. Off until a live run. |
| 2026-10-15 | Virality scores in batch comparison (issue #45): built on the guessed `virality_predictor` call (4.4), off until the export confirms it. Preview, the heatmap and job polling left out. |
| 2026-10-15 | The account's reference elements and Soul characters as reference sources (issue #43): built on the guessed `show_reference_elements` and `show_characters` calls (4.4), off until the export confirms them. Element images go in by `media_id`. "Save to Higgsfield…" and Soul training left out. |
| 2026-10-15 | Reference images (issue #42): Soul 2, Grok Image 2 and Qwen Image 3 Edit over REST (3.13), from the docs' model pages and open.higgsfield.ai prices; the account's `generate_image` built on guessed calls (4.4), off until the export confirms them. |
| 2026-10-15 | Upscale and Remove Background on a result (issue #41): built on the guessed calls in 4.4, off until the export confirms them. Reframe, Dub and Change Voice left out. |
| 2026-10-15 | Account jobs polled in groups of up to 12 with `jobs_wait`, falling back to `job_status` (issue #44); assumed shape in 4.4. Variants and batch submit not done. |
| 2026-10-15 | Model limits from `models_explore get`, cached per account and read through by Create (issue #46); assumed answer shape in 4.5, to be confirmed by the export (issue #37). |
| 2026-10-15 | Model parameters (issues #40, #23): Seedance `generate_audio` with a source, `bitrate_mode`, and start and end frames on `image-to-video`; Kling `keep_original_sound` and `character_orientation`. From the docs' Seedance 2.5 and Kling 3.0 Motion Control pages and the `image-to-video` price on open.higgsfield.ai. On the account only `generate_audio` is sent; the rest wait for the `models_explore` export (4.5). |
| 2026-10-15 | Seedance 2.5 Edit and Extend over REST (issue #39), from the docs' `video-edit` and `video-extend` pages and their open.higgsfield.ai prices. The account side waits for the MCP mode names (4.5). |
| 2026-10-14 | First version. REST from docs.higgsfield.ai (docs changelog of 2026-08-11) and the app's live contract. MCP OAuth metadata fetched live. MCP tools Jutsu uses verified; others from official tooling and third-party directories. |

---

## Appendix A. REST model catalog

All 84 endpoints from `https://docs.higgsfield.ai/docs/models.md` as of 2026-10-14. Each one is `POST https://api.higgsfield.ai/<endpoint>`.

- `*` marks a required field, and `[a-b]` an allowed range.
- Enum values are left out; see each model's page.
- Each page link is also available as Markdown: append `.md`.

### Video (67)

| Model | Endpoint | Fields |
|---|---|---|
| [Cinema Studio 4.0 — Generate](https://docs.higgsfield.ai/docs/models/cinema-studio-4/generate) | `higgsfield/cinema-studio/4.0` | `era`, `genre`, `light`, `pacing`, `*prompt`, `duration` [4-30], `audio_urls`, `image_urls`, `resolution`, `video_urls`, `camera_lens`, `aspect_ratio`, `camera_model`, `color_palette`, `generate_audio`, `camera_aperture`, `camera_movement` |
| [Genjutsu — Motion transfer](https://docs.higgsfield.ai/docs/models/genjutsu/motion-transfer) | `higgsfield/genjutsu/motion-transfer/v1.0` | `prompt`, `*video_url`, `*image_urls`, `resolution` |
| [Genjutsu — Object swap](https://docs.higgsfield.ai/docs/models/genjutsu/object-swap) | `higgsfield/genjutsu/object-swap/v1.0` | `prompt`, `*video_url`, `*image_urls`, `resolution` |
| [Genjutsu — Restyle](https://docs.higgsfield.ai/docs/models/genjutsu/restyle) | `higgsfield/genjutsu/restyle/v1.0` | `prompt`, `*preset_id`, `*video_url`, `image_urls`, `resolution` |
| [Grok Imagine Video 1.5 — Reference to video](https://docs.higgsfield.ai/docs/models/grok-video-1-5/reference-to-video) | `xai/grok-imagine-video/v1.5/reference-to-video` | `*prompt`, `duration` [1-15], `audio_url`, `image_url`, `image_urls`, `resolution`, `aspect_ratio` |
| [Hailuo 2.3 — Standard image to video](https://docs.higgsfield.ai/docs/models/hailuo-2-3/standard-image-to-video) | `minimax/hailuo-2.3/standard/image-to-video` | `*prompt`, `duration`, `*image_url`, `prompt_optimizer` |
| [Hailuo 2.3 — Standard text to video](https://docs.higgsfield.ai/docs/models/hailuo-2-3/standard-text-to-video) | `minimax/hailuo-2.3/standard/text-to-video` | `*prompt`, `duration`, `prompt_optimizer` |
| [HappyHorse 1.1 — Image to video](https://docs.higgsfield.ai/docs/models/happy-horse-1-1/image-to-video) | `alibaba/happy-horse/v1.1/image-to-video` | `seed` [1-2147483646], `prompt`, `duration` [2-15], `*image_url`, `resolution` |
| [HappyHorse 1.1 — Reference to video](https://docs.higgsfield.ai/docs/models/happy-horse-1-1/reference-to-video) | `alibaba/happy-horse/v1.1/reference-to-video` | `seed` [1-2147483646], `*prompt`, `duration` [2-15], `*image_urls`, `resolution` |
| [HappyHorse 1.1 — Text to video](https://docs.higgsfield.ai/docs/models/happy-horse-1-1/text-to-video) | `alibaba/happy-horse/v1.1/text-to-video` | `seed` [1-2147483646], `*prompt`, `duration` [3-15], `resolution`, `aspect_ratio` |
| [Happy Horse 1.0 — Image to video](https://docs.higgsfield.ai/docs/models/happy-horse-1/image-to-video) | `alibaba/happy-horse/image-to-video` | `seed` [1-2147483646], `prompt`, `duration` [2-15], `*image_url`, `resolution` |
| [Happy Horse 1.0 — Reference to video](https://docs.higgsfield.ai/docs/models/happy-horse-1/reference-to-video) | `alibaba/happy-horse/reference-to-video` | `seed` [1-2147483646], `*prompt`, `duration` [2-15], `*image_urls`, `resolution` |
| [Happy Horse 1.0 — Text to video](https://docs.higgsfield.ai/docs/models/happy-horse-1/text-to-video) | `alibaba/happy-horse/text-to-video` | `seed` [1-2147483646], `*prompt`, `duration` [3-15], `resolution`, `aspect_ratio` |
| [Kling 2.5 Turbo — Pro image to video](https://docs.higgsfield.ai/docs/models/kling-2-5-turbo/pro-image-to-video) | `kling-video/v2.5-turbo/pro/image-to-video` | `*prompt`, `duration`, `cfg_scale` [0-1], `*image_url`, `negative_prompt` |
| [Kling 2.5 Turbo — Pro text to video](https://docs.higgsfield.ai/docs/models/kling-2-5-turbo/pro-text-to-video) | `kling-video/v2.5-turbo/pro/text-to-video` | `*prompt`, `duration`, `cfg_scale` [0-1], `negative_prompt` |
| [Kling 2.5 Turbo — Standard image to video](https://docs.higgsfield.ai/docs/models/kling-2-5-turbo/standard-image-to-video) | `kling-video/v2.5-turbo/standard/image-to-video` | `*prompt`, `duration`, `cfg_scale` [0-1], `*image_url`, `negative_prompt` |
| [Kling 2.6 Motion Control — Pro](https://docs.higgsfield.ai/docs/models/kling-2-6-motion-control/pro) | `kling-video/motion-control/pro` | `prompt`, `*image_url`, `*video_url`, `keep_original_sound`, `character_orientation` |
| [Kling 2.6 Motion Control — Standard](https://docs.higgsfield.ai/docs/models/kling-2-6-motion-control/std) | `kling-video/motion-control/std` | `prompt`, `*image_url`, `*video_url`, `keep_original_sound`, `character_orientation` |
| [Kling 2.6 — Pro image to video](https://docs.higgsfield.ai/docs/models/kling-2-6/pro-image-to-video) | `kling-video/v2.6/pro/image-to-video` | `sound`, `*prompt`, `duration`, `cfg_scale` [0-1], `*image_url`, `aspect_ratio` |
| [Kling 2.6 — Pro text to video](https://docs.higgsfield.ai/docs/models/kling-2-6/pro-text-to-video) | `kling-video/v2.6/pro/text-to-video` | `sound`, `*prompt`, `duration`, `cfg_scale` [0-1], `aspect_ratio` |
| [Kling 3.0 Motion Control — Pro](https://docs.higgsfield.ai/docs/models/kling-3-motion-control/pro) | `kling-video/v3/motion-control/pro` | `prompt`, `*image_url`, `*video_url`, `keep_original_sound`, `character_orientation` |
| [Kling 3.0 Motion Control — Standard](https://docs.higgsfield.ai/docs/models/kling-3-motion-control/std) | `kling-video/v3/motion-control/std` | `prompt`, `*image_url`, `*video_url`, `keep_original_sound`, `character_orientation` |
| [Kling 3.0 — 4K · Image to video](https://docs.higgsfield.ai/docs/models/kling-3/4k-image-to-video) | `kling-video/v3.0/4k/image-to-video` | `sound`, `prompt`, `duration` [3-15], `elements`, `cfg_scale` [0-1], `*image_url`, `multi_shots`, `multi_prompt`, `last_image_url` |
| [Kling 3.0 — 4K · Text to video](https://docs.higgsfield.ai/docs/models/kling-3/4k-text-to-video) | `kling-video/v3.0/4k/text-to-video` | `sound`, `prompt`, `duration` [3-15], `elements`, `cfg_scale` [0-1], `multi_shots`, `aspect_ratio`, `multi_prompt` |
| [Kling 3.0 — Pro · Image to video](https://docs.higgsfield.ai/docs/models/kling-3/pro-image-to-video) | `kling-video/v3.0/pro/image-to-video` | `sound`, `prompt`, `duration` [3-15], `elements`, `cfg_scale` [0-1], `*image_url`, `multi_shots`, `multi_prompt`, `last_image_url` |
| [Kling 3.0 — Pro · Text to video](https://docs.higgsfield.ai/docs/models/kling-3/pro-text-to-video) | `kling-video/v3.0/pro/text-to-video` | `sound`, `prompt`, `duration` [3-15], `elements`, `cfg_scale` [0-1], `multi_shots`, `aspect_ratio`, `multi_prompt` |
| [Kling 3.0 — Standard · Image to video](https://docs.higgsfield.ai/docs/models/kling-3/standard-image-to-video) | `kling-video/v3.0/std/image-to-video` | `sound`, `prompt`, `duration` [3-15], `elements`, `cfg_scale` [0-1], `*image_url`, `multi_shots`, `multi_prompt`, `last_image_url` |
| [Kling 3.0 — Standard · Text to video](https://docs.higgsfield.ai/docs/models/kling-3/standard-text-to-video) | `kling-video/v3.0/std/text-to-video` | `sound`, `prompt`, `duration` [3-15], `elements`, `cfg_scale` [0-1], `multi_shots`, `aspect_ratio`, `multi_prompt` |
| [Kling 3.0 — Turbo · Image to video](https://docs.higgsfield.ai/docs/models/kling-3/turbo-image-to-video) | `kling-video/v3.0-turbo/image-to-video` | `*prompt`, `duration` [3-15], `*image_url`, `resolution` |
| [Kling 3.0 — Turbo · Text to video](https://docs.higgsfield.ai/docs/models/kling-3/turbo-text-to-video) | `kling-video/v3.0-turbo/text-to-video` | `*prompt`, `duration` [3-15], `resolution`, `aspect_ratio` |
| [Kling O3 — First last frame](https://docs.higgsfield.ai/docs/models/kling-o3/first-last-frame) | `kling-video/o3/first-last-frame` | `mode`, `sound`, `prompt`, `duration` [3-15], `multi_shots`, `aspect_ratio`, `multi_prompt`, `last_frame_url`, `first_frame_url` |
| [Kling O3 — Image reference](https://docs.higgsfield.ai/docs/models/kling-o3/image-reference) | `kling-video/o3/image-reference` | `mode`, `sound`, `prompt`, `duration` [3-15], `elements`, `shot_type`, `image_urls`, `multi_shots`, `aspect_ratio`, `multi_prompt`, `last_frame_url`, `first_frame_url` |
| [Kling O3 — Video edit](https://docs.higgsfield.ai/docs/models/kling-o3/video-edit) | `kling-video/o3/video-edit` | `mode`, `*prompt`, `elements`, `image_urls`, `*video_urls` |
| [Kling O3 — Video reference](https://docs.higgsfield.ai/docs/models/kling-o3/video-reference) | `kling-video/o3/video-reference` | `mode`, `*prompt`, `duration` [3-10], `elements`, `image_urls`, `*video_urls`, `aspect_ratio` |
| [Kling Omni — First last frame](https://docs.higgsfield.ai/docs/models/kling-omni/first-last-frame) | `kling-video/omni/first-last-frame` | `mode`, `*prompt`, `duration`, `aspect_ratio`, `last_frame_url`, `*first_frame_url` |
| [Kling Omni — Image reference](https://docs.higgsfield.ai/docs/models/kling-omni/image-reference) | `kling-video/omni/image-reference` | `mode`, `*prompt`, `duration` [3-10], `elements`, `image_urls`, `aspect_ratio` |
| [Kling Omni — Video edit](https://docs.higgsfield.ai/docs/models/kling-omni/video-edit) | `kling-video/omni/video-edit` | `mode`, `*prompt`, `elements`, `image_urls`, `*video_urls` |
| [Kling Omni — Video reference](https://docs.higgsfield.ai/docs/models/kling-omni/video-reference) | `kling-video/omni/video-reference` | `mode`, `*prompt`, `duration` [3-10], `elements`, `image_urls`, `*video_urls`, `aspect_ratio` |
| [LTX-2.5 — Image to video fast](https://docs.higgsfield.ai/docs/models/ltx-2-5/image-to-video-fast) | `lightricks/ltx-2.5/image-to-video/fast` | `fps`, `*prompt`, `*duration`, `*image_url`, `resolution`, `aspect_ratio`, `end_image_url`, `generate_audio`, `camera_movement` |
| [LTX-2.5 — Image to video pro](https://docs.higgsfield.ai/docs/models/ltx-2-5/image-to-video-pro) | `lightricks/ltx-2.5/image-to-video/pro` | `fps`, `*prompt`, `*duration`, `*image_url`, `resolution`, `aspect_ratio`, `end_image_url`, `generate_audio`, `camera_movement` |
| [LTX-2.5 — Text to video fast](https://docs.higgsfield.ai/docs/models/ltx-2-5/text-to-video-fast) | `lightricks/ltx-2.5/text-to-video/fast` | `fps`, `*prompt`, `*duration`, `resolution`, `aspect_ratio`, `generate_audio`, `camera_movement` |
| [LTX-2.5 — Text to video pro](https://docs.higgsfield.ai/docs/models/ltx-2-5/text-to-video-pro) | `lightricks/ltx-2.5/text-to-video/pro` | `fps`, `*prompt`, `*duration`, `resolution`, `aspect_ratio`, `generate_audio`, `camera_movement` |
| [MiniMax H3 — Image to video](https://docs.higgsfield.ai/docs/models/minimax-h3/image-to-video) | `minimax/h3/image-to-video` | `*prompt`, `duration` [5-15], `*image_url`, `resolution`, `aspect_ratio`, `end_image_url`, `aigc_watermark` |
| [MiniMax H3 — Reference to video](https://docs.higgsfield.ai/docs/models/minimax-h3/reference-to-video) | `minimax/h3/reference-to-video` | `*prompt`, `duration` [5-15], `audio_urls`, `image_urls`, `resolution`, `video_urls`, `aspect_ratio`, `aigc_watermark` |
| [MiniMax H3 — Text to video](https://docs.higgsfield.ai/docs/models/minimax-h3/text-to-video) | `minimax/h3/text-to-video` | `*prompt`, `duration` [5-15], `resolution`, `aspect_ratio`, `aigc_watermark` |
| [PixVerse V6 — Image to video](https://docs.higgsfield.ai/docs/models/pixverse-v6/image-to-video) | `pixverse/v6/image-to-video` | `seed` [0-2147483647], `*prompt`, `duration` [1-15], `*image_url`, `resolution`, `end_image_url`, `generate_audio`, `negative_prompt` |
| [PixVerse V6 — Text to video](https://docs.higgsfield.ai/docs/models/pixverse-v6/text-to-video) | `pixverse/v6/text-to-video` | `seed` [0-2147483647], `*prompt`, `duration` [1-15], `resolution`, `aspect_ratio`, `generate_audio`, `negative_prompt` |
| [Seedance 2.5 — Image to video](https://docs.higgsfield.ai/docs/models/seedance-2-5/image-to-video) | `bytedance/seedance-2.5/image-to-video` | `prompt`, `duration` [4-30], `*image_url`, `resolution`, `bitrate_mode`, `end_image_url`, `generate_audio` |
| [Seedance 2.5 — Reference to video](https://docs.higgsfield.ai/docs/models/seedance-2-5/reference-to-video) | `bytedance/seedance-2.5/reference-to-video` | `prompt`, `duration` [4-30], `audio_urls`, `image_urls`, `resolution`, `video_urls`, `aspect_ratio`, `bitrate_mode`, `generate_audio` |
| [Seedance 2.5 — Text to video](https://docs.higgsfield.ai/docs/models/seedance-2-5/text-to-video) | `bytedance/seedance-2.5/text-to-video` | `*prompt`, `duration` [4-30], `resolution`, `aspect_ratio`, `bitrate_mode`, `output_format`, `generate_audio` |
| [Seedance 2.5 — Video edit](https://docs.higgsfield.ai/docs/models/seedance-2-5/video-edit) | `bytedance/seedance-2.5/video-edit` | `*prompt`, `*video_url`, `audio_urls`, `image_urls`, `resolution`, `video_urls`, `bitrate_mode`, `generate_audio` |
| [Seedance 2.5 — Video extend](https://docs.higgsfield.ai/docs/models/seedance-2-5/video-extend) | `bytedance/seedance-2.5/video-extend` | `*prompt`, `duration` [4-30], `*video_url`, `audio_urls`, `image_urls`, `resolution`, `video_urls`, `bitrate_mode`, `generate_audio` |
| [Seedance 2.0 — Image to video](https://docs.higgsfield.ai/docs/models/seedance-2/image-to-video) | `bytedance/seedance-2.0/image-to-video` | `prompt`, `duration` [4-15], `*image_url`, `resolution`, `end_image_url`, `generate_audio` |
| [Seedance 2.0 — Reference to video](https://docs.higgsfield.ai/docs/models/seedance-2/reference-to-video) | `bytedance/seedance-2.0/reference-to-video` | `prompt`, `duration` [4-15], `audio_urls`, `image_urls`, `resolution`, `video_urls`, `aspect_ratio`, `generate_audio` |
| [Seedance 2.0 — Text to video](https://docs.higgsfield.ai/docs/models/seedance-2/text-to-video) | `bytedance/seedance-2.0/text-to-video` | `*prompt`, `duration` [4-15], `resolution`, `aspect_ratio`, `generate_audio` |
| [Wan 2.6 — Image to video](https://docs.higgsfield.ai/docs/models/wan-2-6/image-to-video) | `wan/v2.6/image-to-video` | `seed` [-1-10000000], `*prompt`, `duration`, `audio_url`, `*image_url`, `resolution`, `multi_shots`, `prompt_extend`, `negative_prompt` |
| [Wan 2.6 — Reference to video](https://docs.higgsfield.ai/docs/models/wan-2-6/reference-to-video) | `wan/v2.6/reference-to-video` | `*prompt`, `duration`, `resolution`, `*video_urls`, `aspect_ratio` |
| [Wan 2.6 — Text to video](https://docs.higgsfield.ai/docs/models/wan-2-6/text-to-video) | `wan/v2.6/text-to-video` | `seed` [-1-10000000], `*prompt`, `duration`, `audio_url`, `resolution`, `multi_shots`, `prompt_extend` |
| [Wan 2.7 — Image to video](https://docs.higgsfield.ai/docs/models/wan-2-7/image-to-video) | `wan/v2.7/image-to-video` | `seed` [1-2147483646], `prompt`, `duration` [2-15], `audio_url`, `*image_url`, `resolution`, `end_image_url`, `prompt_extend`, `negative_prompt` |
| [Wan 2.7 — Reference to video](https://docs.higgsfield.ai/docs/models/wan-2-7/reference-to-video) | `wan/v2.7/reference-to-video` | `seed` [1-2147483646], `*prompt`, `duration` [2-10], `image_urls`, `resolution`, `video_urls`, `aspect_ratio`, `prompt_extend`, `negative_prompt` |
| [Wan 2.7 — Text to video](https://docs.higgsfield.ai/docs/models/wan-2-7/text-to-video) | `wan/v2.7/text-to-video` | `seed` [1-2147483646], `*prompt`, `duration` [2-15], `audio_url`, `resolution`, `aspect_ratio`, `prompt_extend`, `negative_prompt` |
| [Wan 3.0 Prime — Image to video](https://docs.higgsfield.ai/docs/models/wan-3-prime/image-to-video) | `alibaba/wan-3.0-prime/image-to-video` | `seed` [0-2147483647], `*prompt`, `duration` [2-30], `*image_url`, `resolution`, `aspect_ratio`, `end_image_url`, `generate_audio`, `enable_thinking` |
| [Wan 3.0 Prime — Reference to video](https://docs.higgsfield.ai/docs/models/wan-3-prime/reference-to-video) | `alibaba/wan-3.0-prime/reference-to-video` | `seed` [0-2147483647], `*prompt`, `duration` [2-30], `file_url`, `link_url`, `audio_urls`, `image_urls`, `resolution`, `video_urls`, `aspect_ratio`, `generate_audio`, `enable_thinking` |
| [Wan 3.0 Prime — Text to video](https://docs.higgsfield.ai/docs/models/wan-3-prime/text-to-video) | `alibaba/wan-3.0-prime/text-to-video` | `seed` [0-2147483647], `*prompt`, `duration` [2-30], `resolution`, `aspect_ratio`, `generate_audio`, `enable_thinking` |
| [Wan 3.0 — Image to video](https://docs.higgsfield.ai/docs/models/wan-3/image-to-video) | `alibaba/wan-3.0/image-to-video` | `seed` [0-2147483647], `*prompt`, `duration` [2-30], `*image_url`, `resolution`, `aspect_ratio`, `end_image_url`, `generate_audio`, `enable_thinking` |
| [Wan 3.0 — Reference to video](https://docs.higgsfield.ai/docs/models/wan-3/reference-to-video) | `alibaba/wan-3.0/reference-to-video` | `seed` [0-2147483647], `*prompt`, `duration` [2-30], `file_url`, `link_url`, `audio_urls`, `image_urls`, `resolution`, `video_urls`, `aspect_ratio`, `generate_audio`, `enable_thinking` |
| [Wan 3.0 — Text to video](https://docs.higgsfield.ai/docs/models/wan-3/text-to-video) | `alibaba/wan-3.0/text-to-video` | `seed` [0-2147483647], `*prompt`, `duration` [2-30], `resolution`, `aspect_ratio`, `generate_audio`, `enable_thinking` |

### Image (17)

| Model | Endpoint | Fields |
|---|---|---|
| [Ads Studio — Generate ads](https://docs.higgsfield.ai/docs/models/ads-studio/generate) | `higgsfield/ads-studio/v1.0` | `niche`, `*prompt`, `language`, `batch_size` [1-8], `image_urls`, `aspect_ratio`, `target_audience` |
| [Grok Image 2.0 — Generate and edit](https://docs.higgsfield.ai/docs/models/grok-image-2/generate-and-edit) | `xai/grok-imagine-image-2.0` | `*prompt`, `quality`, `image_urls`, `resolution`, `aspect_ratio` |
| [Ideogram 4.0 — Generate](https://docs.higgsfield.ai/docs/models/ideogram-4/generate) | `ideogram/v4.0` | `*prompt`, `image_url`, `aspect_ratio`, `image_weight` [1-100], `rendering_speed` |
| [Marketing Studio Image — 2.5 Flare](https://docs.higgsfield.ai/docs/models/marketing-studio-image/flare) | `marketing-studio/image/flare` | `*prompt`, `quality`, `preset_id`, `image_urls`, `moderation`, `resolution`, `aspect_ratio`, `enhance_prompt` |
| [Marketing Studio Image — 2.0 Alpha](https://docs.higgsfield.ai/docs/models/marketing-studio-image/generate-and-edit) | `marketing-studio/image` | `*prompt`, `quality`, `preset_id`, `image_urls`, `moderation`, `resolution`, `aspect_ratio`, `enhance_prompt` |
| [Marketing Studio Image — 2.5 Sunburst](https://docs.higgsfield.ai/docs/models/marketing-studio-image/sunburst) | `marketing-studio/image/sunburst` | `*prompt`, `quality`, `preset_id`, `image_urls`, `moderation`, `resolution`, `aspect_ratio`, `enhance_prompt` |
| [Qwen Image 3 — Edit images](https://docs.higgsfield.ai/docs/models/qwen-image-3/edit) | `alibaba/qwen-image-3/edit` | `seed` [0-2147483647], `*prompt`, `*image_urls`, `resolution`, `aspect_ratio`, `prompt_extend`, `enable_thinking`, `negative_prompt`, `prompt_extend_mode` |
| [Qwen Image 3 — Text to image](https://docs.higgsfield.ai/docs/models/qwen-image-3/text-to-image) | `alibaba/qwen-image-3/text-to-image` | `seed` [0-2147483647], `*prompt`, `resolution`, `aspect_ratio`, `prompt_extend`, `enable_thinking`, `negative_prompt`, `prompt_extend_mode` |
| [Recraft V4.1 Pro — Text to image](https://docs.higgsfield.ai/docs/models/recraft-v4-1-pro/generate) | `recraft/v4.1/pro/text-to-image` | `colors`, `*prompt`, `resolution`, `aspect_ratio`, `output_format`, `background_color` |
| [Recraft V4.1 Utility Pro — Text to image](https://docs.higgsfield.ai/docs/models/recraft-v4-1-utility-pro/text-to-image) | `recraft/v4.1/utility/pro/text-to-image` | `colors`, `*prompt`, `resolution`, `aspect_ratio`, `output_format`, `background_color` |
| [Recraft V4.1 Utility — Text to image](https://docs.higgsfield.ai/docs/models/recraft-v4-1-utility/text-to-image) | `recraft/v4.1/utility/text-to-image` | `colors`, `*prompt`, `resolution`, `aspect_ratio`, `output_format`, `background_color` |
| [Recraft V4.1 — Text to image](https://docs.higgsfield.ai/docs/models/recraft-v4-1/text-to-image) | `recraft/v4.1/text-to-image` | `colors`, `*prompt`, `resolution`, `aspect_ratio`, `output_format`, `background_color` |
| [SOUL V2 — Text to image](https://docs.higgsfield.ai/docs/models/soul-2/generate) | `higgsfield-ai/soul/v2/standard` | `*prompt`, `aspect_ratio`, `resolution`, `enhance_prompt`, `custom_reference_id`, `custom_reference_strength` [0-1], `style_id`, `style_strength` [0-1], `seed` [1-1000000], `batch_size` |
| [SOUL Cinema — Text to image](https://docs.higgsfield.ai/docs/models/soul-cinema/generate) | `higgsfield-ai/soul/cinema` | `*prompt`, `aspect_ratio`, `enhance_prompt`, `resolution`, `custom_reference_id`, `custom_reference_strength` [0-1], `seed` [1-1000000], `batch_size` |
| [Soul ID — Create character](https://docs.higgsfield.ai/docs/models/soul-id/create-character) | `v1/custom-references` | `*name`, `model_version`, `*input_images` |
| [SOUL — Text to image](https://docs.higgsfield.ai/docs/models/soul-standard/generate) | `higgsfield-ai/soul/standard` | `*prompt`, `aspect_ratio`, `enhance_prompt`, `style_id`, `style_strength` [0-1], `resolution`, `seed`, `custom_reference_id`, `custom_reference_strength` [0-1], `image_reference_url`, `batch_size` |
| [Z-Image Turbo — Generate](https://docs.higgsfield.ai/docs/models/z-image-turbo/generate) | `z-image/turbo` | `seed` [0-2147483647], `*prompt`, `resolution`, `aspect_ratio`, `prompt_extend` |

## Appendix B. MCP tools Jutsu doesn't use

Status: **Unverified**. Names come from Higgsfield's official plugin and CLI. Descriptions and arguments come from third-party MCP directories as of 2026-10-14. Confirm with the live catalog (issue #37) before building on them. Rows marked "checked against the snapshot" were compared with `docs/mcp-snapshots/2026-10-15.json`.

**Generation**

| Tool | Purpose | Notes |
|---|---|---|
| `generate_image` | One image request | `count` 2–4 for variants; models from `models_explore {type: "image"}`; the image role per model (`image` or `image_references`). Used, on (4.4, issue #42) |
| `generate_image_batch`, `generate_video_batch`, `generate_audio_batch` | 1–12 independent requests | **Checked against the snapshot of 2026-10-15** for `generate_video_batch`: `requests: [{index, params}]`, `params` as `generate_video`'s with `count` fixed to 1 and no `get_cost`; answers `{jobs: [{index, job_id, status, error}], submitted_count, failed_count}`; `idempotentHint: false`, so unused (4.4, issue #44) |
| `generate_audio` | Text to speech | Default model `seed_audio`; voices from `list_voices` |
| `generate_3d` | GLB mesh from an image | `animation_actions` lists rig animations |
| `jobs_wait` | Long-poll ≤12 jobs, ≤15 s | **Checked against the snapshot of 2026-10-15:** `jobs: [{job_id, index}]` (1–12), `timeout_seconds` 0–15 (default 15); read-only, idempotent. Answer per `outputSchema`: `jobs[]` (`index`, `job_id`, `status`, `result_url`, `error`, `retryable`), `summary`, `all_terminal`, `poll_after_seconds`, `timed_out`. Jutsu polls account jobs with it (4.4, issue #44); the answer was confirmed live on 2026-10-15 (issue #114) |
| `job_status` extras | `sync: true` waits up to ~25 s; `raw_data`; `poll_after_seconds` in the answer | Jutsu uses only `jobId` |
| `models_explore` | `list` / `search` / `get` / `recommend` models | **Checked against the snapshot of 2026-10-15:** `action`, `type`, `model_id`, `query`, `input`, `unlim` (filter), `limit` ≤100, `after`; `list` answers `{items, has_more, next_page_token, unlim}`, `get` the model with `parameters[]`, `medias[]`, `supports_unlim`, `unlim`. Jutsu uses `list` and `get` (4.5, issues #46, #22) |
| `presets_show` | Image-to-video presets | |

**Editing an existing result**

| Tool | Purpose | Notes (issue #41) |
|---|---|---|
| `upscale_video` | Upscale and enhance | `params.video_id`; `provider` `bytedance` (1080p/2K/4K, needs source size, `fps` 24/30/60) or `topaz` (1080p/2160p); no cost preflight. Used, on (4.4) |
| `upscale_image` | Upscale an image | |
| `reframe` | New aspect ratio with outpainting | `params.medias` (one video), `aspect_ratio`; `get_cost`. Used, on (4.4) |
| `outpaint_image` | Extend an image's canvas | |
| `remove_background` | Cut out the subject of an image or video | `params.media_id`, `media_type`. Used, on (4.4) |
| `motion_control` | Kling 3.0 Motion Control as a dedicated tool | `image_id`, `motion_video_id` |
| `dubbing` | Translate and lip-sync | `params.video_id`, `target_language`. Used, on (4.4) |
| `voice_change` | Replace the voice | `params.video_id`, `voice_id`, `voice_type`. Used, on (4.4) |
| `list_voices`, `create_voice` | Voice catalog and custom voices | `list_voices` used by Change Voice (4.4) |

**Media, references and workspaces**

| Tool | Purpose | Notes |
|---|---|---|
| `media_import_url` | Import an HTTPS media URL (≤50 MB), returns a confirmed `media_id` | Checked against the snapshot of 2026-10-15: `url`, `type` (`auto`/`image`/`video`/`audio`); answers `media_id`, `type`, `content_type`, `source_url`, `warning`, `error`. Used for linked files on the account (4.4, issues #47, #90) |
| `media_upload` (batch) / `media_confirm` (batch) | `files[]` 1–20 / `media_ids[]` 1–20 | Jutsu uploads one file per call |
| `show_medias` | List uploaded media | Jutsu uses `assets_picker_list` |
| `show_reference_elements` | Reusable characters, environments and props: `list` / `get` / `create` | All three used, on (4.4, issue #43): `create` is Save to Higgsfield… |
| `show_characters` | Soul characters: `list` / `train` (5–20 images) / `status` | Not used: a Soul is a `soul_id` for Soul image models, not a video reference; character sheets are used instead (4.4, issue #109) |
| `show_generation_by_ids`, `job_display` | Show results in a chat widget | Not useful outside chat clients. `show_generation_by_ids` takes `jobs: [{index, job_id}]`; plain ID strings, under `ids` or `jobs`, are refused with an input validation error (live, 2026-10-15) |
| `list_workspaces`, `select_workspace` | Team workspaces; operations target the selected one | Jutsu always uses the default |
| `reveal_generation` | Release an `ip_detected` Seedance-family result after the user confirms rights | |

**Analysis and other products**

| Tool | Purpose |
|---|---|
| `virality_predictor` | Score a video's hook, engagement and sustain: `create` starts a free job, whose `job_status` carries the scores (4.4, issues #45, #111) |
| `video_analysis_create` / `_status` / `_jobs` | Scene-by-scene analysis of an upload or a YouTube link |
| `get_workflow_instructions`, `get_workflow_bundle_file` | Server-side multi-step recipes (for example `ad-multiplier`) |
| `shorts_studio_*`, `personal_clipper_*`, `get_explainer_presets` | Shorts, clipping and explainer products |
| `apps_search` / `apps_describe` / `apps_invoke` | Higgsfield Marketplace apps |
| `tiktok_*` | Connect and publish to TikTok |
| `*_website*`, `sandbox_exec`, `sync_agents` | Hosted websites and agent tooling |
| `show_plans_and_credits`, `cancel_trial_auto_renewal` | Billing UI |
