# Contributing

Start with [ARCHITECTURE.md](ARCHITECTURE.md) for the module layout. New here? Pick an issue labeled [`good first issue`](https://github.com/jutsuhq/jutsu-studio/labels/good%20first%20issue). For anything larger than a small fix, open an issue first.

## Setup

From a clean clone on macOS 14+ with Xcode 26+:

1. Install [Homebrew](https://brew.sh), then [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
2. `xcodegen generate`, then open `JutsuStudio.xcodeproj` and run the `JutsuStudio` scheme.

- The project file, `Info.plist` and the entitlements are generated from `project.yml` and are not committed. Change `project.yml`, not build settings in Xcode, and run `xcodegen generate` again after every change to it (or after pulling one).
- `CODE_SIGN_IDENTITY "-"` signs the app ad hoc so it runs locally without a developer account. Each rebuild is a new signature to the Keychain, so macOS may ask again for access to the saved sign-in or API key; choose Always Allow, or set your own Apple Development team in Xcode to stop the prompts.
- Not on a Mac? `HiggsfieldKit` and the portable part of `JutsuKit` build on Linux. With Docker running, `scripts/test-linux.sh` tests them and `scripts/lint.sh` lints everything.

## Commands

| Command | What it does |
|---|---|
| `scripts/test.sh` | Fast local check: client, provider, domain, queue and presentation tests |
| `scripts/test.sh all` | Full check, including media conversion, persistence and Keychain on macOS |
| `scripts/test.sh app --filter PagedFeedTests` | Build and run one JutsuKit suite; use `kit` for HiggsfieldKit |
| `scripts/test.sh media` | AVFoundation integration tests only |
| `scripts/lint.sh` | swift-format lint, SwiftLint, module import rules, string catalogs. Uses native tools if installed, Docker otherwise |
| `scripts/check-secrets.sh` | Gitleaks scan of the full reachable Git history; install Gitleaks locally. CI downloads a checksum-verified version |
| `scripts/format.sh` | Formats all Swift files in place |
| `scripts/test-linux.sh` | `swift test` for the portable modules in a Linux container |
| `swift test --package-path Packages/JutsuKit` | All JutsuKit tests (macOS) |
| `swift test --package-path Packages/HiggsfieldKit` | Higgsfield client tests |
| `scripts/release.sh` | Signed, notarized DMG and zipped dSYMs in `build/` (macOS, see [Releasing](#releasing)) |
| `scripts/install-xcodegen.sh <dir>` | Downloads the XcodeGen version CI uses, checks its SHA-256 and prints its `bin` directory (macOS) |
| `scripts/smoke-launch.sh <dmg>` | Launches a built app once and fails unless it starts and quits cleanly (macOS) |
| `scripts/release-notes.sh <since> <until> <version>` | The "What changed" notes for a release, from the commits between two refs |

CI runs a full-history secret scan, lint and Linux tests on every PR, then the full package tests and an app build on macOS. The release workflow reuses those checks for the exact tagged commit before the signing job can access its secrets. The tag must point to a commit on `main`, and `SUFeedURL` must point to the repository running the release. That repository must be public with private vulnerability reporting enabled before a binary release.

Dependabot checks GitHub Actions and the hashed Python packaging dependencies weekly. The **Sparkle updates** workflow checks for new stable Sparkle releases weekly: its pin lives in `project.yml`, which Dependabot's SwiftPM updater cannot edit. A failed check means review the new release, update the pin and run the package/app checks.

The cross-volume replacement regression uses `/dev/shm` in Linux CI. To run it on macOS, mount a small disposable writable disk image (under 128 MiB free) and run `JUTSU_REPLACEMENT_TEST_VOLUME=/path/to/mount scripts/test.sh app --filter FileReplacementTests`. The test deliberately exhausts that isolated volume; never point it at a working disk.

Use the fast check while editing and `scripts/test.sh all` before a PR. `--filter` selects tests to run; SwiftPM still builds the test targets, so the first build takes longer. Later runs reuse `.build`. `--skip-build` is only for rerunning an unchanged binary, such as a timing measurement; it doesn't verify source edits.

The scripts use an installed, working Swift toolchain and fall back to Xcode's bundled Swift on macOS if a Swiftly shim points to a missing installation. Builds use four jobs by default; pass `--jobs N` to change that. Both packages are tested with Swift Testing; there are no XCTest suites to launch.

## OAuth client metadata

Optional. By default, account sign-in registers the app dynamically (ARCHITECTURE §5.2), so nothing has to be hosted.

The app can instead identify itself with the Client ID Metadata Document in `docs/oauth-client.json`. During sign-in the authorization server downloads `https://jutsuhq.github.io/jutsu-studio/oauth-client.json`, so that URL has to resolve before this is turned on:

1. Publish the `docs/` folder of `main` with GitHub Pages (Settings → Pages → Deploy from a branch, `main` / `docs`). A private repository needs a plan that allows Pages.
2. Check that `curl -fsS https://jutsuhq.github.io/jutsu-studio/oauth-client.json` returns the file.
3. Pass that URL as `metadataDocumentURL` to `ClientRegistration` in `AccountAuthorization.client`.

Turning it on before the URL resolves makes every sign-in fail.

When changing `docs/oauth-client.json`, keep its `client_id` equal to its own URL and its `redirect_uris` equal to `ClientRegistration.redirectURI`.

## Code rules

- **Module boundaries.** Each module imports only what [scripts/check-architecture.sh](scripts/check-architecture.sh) allows. `JutsuCore` is Foundation-only and has no I/O. SwiftUI/AppKit only in the app target.
- **Portable where possible.** `JutsuCore`, `HiggsfieldProviders`, `JobEngine`, `Presentation` and `HiggsfieldKit` must keep building on Linux: no Apple-only frameworks, `#if canImport(FoundationNetworking)` for `URLSession`.
- **Swift 6, strict concurrency.** No `@unchecked Sendable` or `nonisolated(unsafe)` without a comment saying why it is safe.
- **No force unwraps, force tries or `print`** outside tests. Log with `os.Logger`; mark keys, tokens and signed URLs `privacy: .private`. `privacy: .public` (and `EngineLog`'s message, which must be a literal) takes only counts, IDs, model and tool names, HTTP methods, statuses and hosts, and enum raw values; [scripts/check-log-privacy.sh](scripts/check-log-privacy.sh) checks it and lists the reviewed exceptions.
- **UI text** comes from a string catalog, English being the source: `String(localized: …, bundle: .module)` in `Presentation`, `HiggsfieldProviders` and `JobEngine`, `Text("…")` or `String(localized:)` in the app. Numbers go in as numbers, so plurals and the locale's separators apply. Each key must be in its target's `Localizable.xcstrings`, which [scripts/check-localization.sh](scripts/check-localization.sh) checks on macOS; Xcode adds the app's keys when it builds in the IDE, `xcrun xcstringstool sync` adds a package's from the `.stringsdata` of a `swift build`.
- **Secrets** only in Keychain via the `Secrets` module. Never in `UserDefaults`, SwiftData, files or logs.
- **Tests** with Swift Testing (`import Testing`). New logic ships with tests; networking is tested against `URLProtocol` stubs, never the real API.
- **Comments** explain constraints the code can't (API quirks, units, invariants). No history in comments; that goes in commit messages.
- Formatting is whatever `scripts/format.sh` produces. Don't hand-tune it.

## Releasing

Releases are built by [scripts/release.sh](scripts/release.sh): XcodeGen, a universal Release archive with the hardened runtime, Developer ID export, a notarized and stapled app inside a DMG that is notarized and stapled too, and the archive's dSYMs zipped next to it. `scripts/release.sh --help` lists the options. Pushing a tag `vX.Y.Z` runs the same script in [the release workflow](.github/workflows/release.yml), which attaches the DMG, its `.sha256`, the dSYMs and the Sparkle appcast to a draft GitHub release; the script also runs locally.

The script refuses to release unless `CURRENT_PROJECT_VERSION` in `project.yml` is higher than in the previous `v*` tag. Keep the dSYMs zip with every published release: a crash report (`~/Library/Logs/DiagnosticReports/Jutsu Studio-*.ips`) can only be symbolicated with the dSYMs of the build that produced it.

CI and the release workflow install XcodeGen with [scripts/install-xcodegen.sh](scripts/install-xcodegen.sh), which pins the version and its checksum. To update it, change `VERSION` and `SHA256` there (the checksum is listed on the GitHub release). Dependabot proposes updates to the pinned GitHub Actions.

Before anything is published, the script launches the finished app once from the DMG with [scripts/smoke-launch.sh](scripts/smoke-launch.sh): the app runs with `--smoke-test`, opens its library and first window without starting the queue or touching the network, and has to quit cleanly. Run it on any build with `scripts/smoke-launch.sh build/Jutsu-Studio-X.Y.Z.dmg`.

The draft's notes start from [scripts/release-notes.sh](scripts/release-notes.sh), which lists the commits since the previous tag and leaves out the ones a user can't notice (`test:`, `ci:`, `docs:`, `refactor:`, lint and lock-file commits). Write commit subjects as something a user would read: "Fix a crash when the source file is missing", not "Update CreateView.swift". Then add the summary from [docs/release-notes-template.md](docs/release-notes-template.md) on top.

The installer window (background, icon layout) lives in [scripts/dmg](scripts/dmg): edit `background.html`, run `scripts/dmg/render-background.sh` and commit both PNGs. The script builds the DMG with dmgbuild, which it installs from the hash-pinned `scripts/dmg/requirements.txt` into `build/.dmgbuild`.

### Software Update

The app updates itself with [Sparkle](https://sparkle-project.org). It reads `appcast.xml` from `releases/latest/download/`, so an update reaches installed copies the moment a draft is published, and never before. [scripts/appcast.sh](scripts/appcast.sh) writes that file after `scripts/release.sh`: it signs the DMG with the Sparkle EdDSA key, checks the signature against `SUPublicEDKey` in `project.yml`, and puts the release notes in the feed. Sparkle installs an update only if both that signature and the app's Developer ID signature check out.

The private key was created once with Sparkle's `generate_keys --account jutsu-studio` and lives in the owner's login Keychain; `generate_keys` and `sign_update` are in `build/SourcePackages/artifacts/sparkle/Sparkle/bin` after a release build. The workflow reads it from the `SPARKLE_ED_PRIVATE_KEY` secret:

```sh
generate_keys --account jutsu-studio -x sparkle-key.txt
gh secret set SPARKLE_ED_PRIVATE_KEY --env release < sparkle-key.txt
```

Move `sparkle-key.txt` to the Trash afterwards and keep a backup of the key somewhere safe: without it, installed copies can't be updated, and a new key needs a new `SUPublicEDKey` that only a manual install delivers. Debug builds never check for updates.

### Homebrew cask

[packaging/homebrew/jutsu-studio.rb](packaging/homebrew/jutsu-studio.rb) is the template of the cask; [scripts/update-cask.sh](scripts/update-cask.sh) sets its `version` and `sha256` (`scripts/update-cask.sh X.Y.Z build/Jutsu-Studio-X.Y.Z.dmg.sha256`). The release workflow runs it and attaches the result, `jutsu-studio.rb`, to the draft release; nothing is pushed to the tap. Keep the template's `version` and `sha256` at the latest published release.

The tap is a separate repo, created once:

1. Create the public repo `jutsuhq/homebrew-tap` (the `homebrew-` prefix lets users write `jutsuhq/tap`).
2. Copy the template to `Casks/jutsu-studio.rb` in it and push.
3. Check it on a Mac: `brew install --cask jutsuhq/tap/jutsu-studio`, then `brew audit --cask --online jutsuhq/tap/jutsu-studio`.
4. Add `brew install --cask jutsuhq/tap/jutsu-studio` to the README's download instructions.

After publishing each release, download its `jutsu-studio.rb`, replace `Casks/jutsu-studio.rb` in the tap with it and push; `brew upgrade` then offers the new version. Commit the same `version` and `sha256` to the template here.

### One-time setup

1. Apple Developer Program membership. In Xcode → Settings → Accounts → Manage Certificates, add a **Developer ID Application** certificate (or create it at developer.apple.com and import it into the login keychain). `security find-identity -v -p codesigning` should list `Developer ID Application: <name> (<TEAM_ID>)`.
2. Create an app-specific password at [account.apple.com](https://account.apple.com) → Sign-In and Security, then store notarization credentials in the keychain:
   ```sh
   xcrun notarytool store-credentials jutsu-notary --apple-id <apple-id-email> --team-id <TEAM_ID>
   ```
3. `brew install xcodegen`.

The certificate and the password stay in your keychain. Nothing from this setup goes into the repo or into shell history files.

### GitHub release workflow

The workflow notarizes with an App Store Connect API key instead of an Apple ID. Its secrets live in the `release` environment (Settings → Environments → `release`; limit its deployment branches and tags to `v*`), so pull requests and forks never see them:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | The 10-character Team ID. |
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate with its private key, exported from Keychain Access as `.p12`, base64-encoded. |
| `DEVELOPER_ID_P12_PASSWORD` | The password chosen at export. |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | From App Store Connect → Users and Access → Integrations → Team Keys. |
| `ASC_KEY_P8` | The contents of `AuthKey_<KEY_ID>.p8`. A key with the **Developer** role is enough for notarization. |
| `SPARKLE_ED_PRIVATE_KEY` | The Sparkle update key, see [Software Update](#software-update). |

Set them from the files rather than pasting values into a shell, e.g.:

```sh
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --env release
gh secret set ASC_KEY_P8 --env release < AuthKey_<KEY_ID>.p8
gh secret set DEVELOPER_ID_P12_PASSWORD --env release   # prompts for the value
```

Delete the exported `.p12` afterwards. The same key works locally: `NOTARY_KEY=AuthKey_<KEY_ID>.p8 NOTARY_KEY_ID=… NOTARY_ISSUER=…` replaces `NOTARY_PROFILE`.

### Checklist

- [ ] No keys in the repo. Both commands must print nothing:
  ```sh
  git grep -nIE 'Key [A-Za-z0-9_-]{8,}:[A-Za-z0-9_-]{8,}|HF_[A-Z_]+=[^$[:space:]]|PRIVATE KEY-----'
  git ls-files '*.env' '*.p12' '*.p8' '*.cer' '*.mobileprovision'
  ```
- [ ] Prices in [pricing.json](Packages/JutsuKit/Sources/JutsuCore/Resources/pricing.json) match the model pages listed in its `sources` (Genjutsu, Seedance 2.5, Kling 3.0 Motion Control, Kling O3); bump its `updated` date if they changed.
- [ ] `MARKETING_VERSION` bumped and `CURRENT_PROJECT_VERSION` incremented in `project.yml` (the script fails otherwise), merged to `main`.
- [ ] `scripts/lint.sh` and `swift test` for both packages pass on `main`.
- [ ] README demo GIF and screenshots reflect the current UI.
- [ ] Release notes written from [docs/release-notes-template.md](docs/release-notes-template.md).

### Build and publish

With the workflow: bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, merge to `main`, then `git tag vX.Y.Z && git push origin vX.Y.Z`. The workflow fails if the tag and `project.yml` disagree. Check the DMG as below, fill in the draft release's notes and publish it.

By hand:

```sh
git checkout main && git pull
DEVELOPMENT_TEAM=<TEAM_ID> NOTARY_PROFILE=jutsu-notary scripts/release.sh
```

The script stops at the first failed step. On success it leaves `build/Jutsu-Studio-X.Y.Z.dmg` (signed, notarized, stapled, with a stapled app inside), its `.sha256` and `build/Jutsu-Studio-X.Y.Z-dSYMs.zip`. Before publishing, copy the DMG to a Mac (or a fresh macOS 14 VM) that never had a dev build, open it, drag the app to Applications and launch it: Gatekeeper must open it without a warning.

```sh
cp docs/release-notes-template.md build/release-notes.md   # then fill it in
git tag vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z build/Jutsu-Studio-X.Y.Z.dmg build/Jutsu-Studio-X.Y.Z.dmg.sha256 \
  build/Jutsu-Studio-X.Y.Z-dSYMs.zip --title "Jutsu Studio X.Y.Z" --notes-file build/release-notes.md
```

For a local test build without a certificate, `scripts/release.sh --skip-notarize` signs ad hoc and skips notarization. That DMG only runs on the Mac that built it (or after right-click → Open), so never publish it.

## Adding a video model

A model is an entry in [models.json](Packages/JutsuKit/Sources/JutsuCore/Resources/models.json) (its `notes` explain the fields), its title, family and detail in `Models.xcstrings` next to it, and the rates of each of its endpoints in `pricing.json` at each resolution it renders at; `Pricing` refuses to load with one missing. A model without all of 480p, 720p and 1080p lists its own in `resolutions`, and the picker and `Pricing` follow it. A rate no public page states is `null`, never a guess: the job then shows "Price unknown" until the server quotes it. Where a page gives only a range over all settings, the rate is its top as `{"upTo": rate}`, shown as "up to"; name every rate's page and date in `rateSources`. Its body reuses one of the request shapes (`VideoModelDescriptor.RequestShape`), or a new shape adds an encoder to `APIModel` and `AccountModel.request` and a case to `ModelEndpoint`. A model the public REST docs don't list has empty `endpoints`: it runs on the account only and needs no rates (MiniMax H3 Max). The account's model ID is data: set `request.account` only once the model's `models_explore get` in the newest catalog snapshot (`docs/mcp-snapshots/`) confirms the ID, the media roles and every parameter the shape sends, and add the model to the snapshot test in `MoreVideoModelsTests` (`CatalogSnapshot.violations(ofParams:)`); without it, the model runs with an API key only. Leave out `credits` until a `get_cost` quote shows the account's rate. Never change an existing `id`; jobs, templates and settings store it.

## Branches and PRs

- Branch per issue: `issue-<number>-<slug>`, e.g. `issue-5-core`.
- One issue per PR, `Closes #<number>` in the description, fill in the PR template.
- Commit messages: imperative subject ≤ 72 chars, body explains why.
- PRs are squash-merged after CI is green and the review is done.
