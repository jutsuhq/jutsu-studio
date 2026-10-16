#!/usr/bin/env bash
# Build and test HiggsfieldKit and the portable part of JutsuKit in a Linux container.
# The build cache lives in a Docker volume per checkout, so it never mixes with macOS .build output
# or with other worktrees.
set -euo pipefail
source "$(dirname "$0")/_docker.sh"
cd "$(repo_root)"

volume="jutsukit-linux-$(pwd | cksum | awk '{print $1}')"
for package in HiggsfieldKit JutsuKit; do
    in_docker "$SWIFT_IMAGE" -v "$volume:/cache" -- \
        swift test --package-path "Packages/$package" --scratch-path "/cache/$package" "$@"
done
