<!-- Copy to build/release-notes.md, fill in X.Y.Z and the SHA-256, drop sections that don't apply.
     Publish with the DMG, its .sha256 and the dSYMs zip, as in CONTRIBUTING.md, "Build and publish". -->

Jutsu Studio X.Y.Z, an unofficial desktop app for Higgsfield on macOS.

> **Unofficial.** Jutsu Studio is a community-built tool, not affiliated with, endorsed by, or connected to Higgsfield AI. Higgsfield, Genjutsu, Seedance, Kling and other model names are trademarks of their respective owners.
> **You pay Higgsfield, not us.** Generations are billed to your own Higgsfield account (plan credits or API balance) at list prices. Jutsu Studio is free and takes no cut.

## Install

1. Download `Jutsu-Studio-X.Y.Z.dmg` below, open it and drag **Jutsu Studio** to Applications.
2. Launch it and connect Higgsfield: **Connect your Higgsfield account** (plan credits) or paste an API key from the [Higgsfield console](https://console.higgsfield.ai).

Requires macOS 14 Sonoma or later, Apple silicon or Intel. The app is signed with a Developer ID and notarized by Apple.

## What's in v0.1

- **Three Genjutsu modes:** motion transfer, object swap and restyle in one window.
- **Two ways to log in:** your Higgsfield account through Higgsfield's MCP server, or your own API key. Both are stored in the macOS Keychain.
- **Smart input prep:** native AVFoundation transcode, 4–30 s range trimming, HEIC→JPEG, automatic fit to the 200 MiB limit, the object-swap pixel check.
- **Cost before you pay:** a live price tag on every job, an optional daily spend cap. Failed, NSFW-rejected and canceled jobs are not charged.
- **Quick Preview:** a 480p draft for about a dollar before you render the 720p/1080p final.
- **Preset manager:** the restyle catalog with previews and search, cached locally.
- **Queue:** run jobs within your concurrency limit, keep working in the background, resume after a restart; one idempotency key per job so retries never double-charge.
- **Local library:** results downloaded to `~/Movies/Jutsu Studio` with their inputs, prompt and cost; before/after toggle, "render final" and "edit & re-run".
- **Private by design:** no backend, no telemetry; everything stays on your Mac.

## Changes since vPREVIOUS

<!-- From: git log --oneline vPREVIOUS..vX.Y.Z. Delete this section for the first release. -->

-

## Known issues

-

## Checksum

```
SHA-256  <paste build/Jutsu-Studio-X.Y.Z.dmg.sha256>
```
