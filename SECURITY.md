# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** (private vulnerability reporting). The report stays visible only to the maintainers until an advisory is published. Don't open a public issue or pull request for a vulnerability.

Include the app version, macOS version, steps to reproduce and what an attacker gains. You'll get an answer in the advisory thread; fixes ship in a new release, and the advisory is published once that release is out.

Only the latest release is supported.

## Threat model

Jutsu Studio is a native macOS client for Higgsfield. It has no server and no account of its own: you bring your own Higgsfield account, either by signing in (OAuth with PKCE in your browser, through Higgsfield's MCP server) or with a Higgsfield API key. Generations are billed to that account.

**Secrets.** API keys, access and refresh tokens and the OAuth client registration are stored only in the macOS login keychain (generic password, not synchronized). They are never written to `UserDefaults`, the SwiftData store, files or logs. Errors, URLs and signed URLs are logged as private in the unified log.

**Network.** The app contacts Higgsfield, GitHub for updates, and the host of a link you paste:

| Host | What is sent |
|---|---|
| `api.higgsfield.ai` | With an API key: job requests, uploads of the source video, reference images and prompt, status polling |
| `mcp.higgsfield.ai` and the OAuth authorization server it advertises | With a sign-in: the OAuth flow (in your browser and the token endpoint), then the same jobs as MCP tool calls |
| Higgsfield storage (presigned URLs returned by the two above) | Upload of inputs, download of results and preview media |
| `github.com` and its release downloads | Software Update: once a day (unless turned off in Settings) the appcast of the latest release, and the update you install. Sparkle sends no system profile |
| The host of a link you paste or drop | A plain download of that file, as an input |

There is no telemetry, analytics or crash reporting, and no other host is contacted. Links in the app (Higgsfield console, this repository) open in your browser only when you click them. During sign-in the app listens on `127.0.0.1` for the OAuth redirect and stops listening when the sign-in ends.

**Local data.** Everything else stays on your Mac, inside the App Sandbox:

- Results: `~/Movies/Jutsu Studio/`, or a folder you choose (kept as a security-scoped bookmark).
- History, prepared inputs and caches: `~/Library/Containers/<bundle id>/Data/Library/Application Support/Jutsu Studio/`.
- Settings: the app's `UserDefaults`, with no secrets.
- Short-lived scratch files: the sandbox's temporary directory, and hidden `.<job id>.partial` files next to a result while it downloads.

**Out of scope.** Higgsfield's own services and how they handle uploaded media; a compromised Mac or user account (anything that can read your Keychain or your files can read the app's).
