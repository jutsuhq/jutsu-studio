#!/usr/bin/env bash
# Rewrite Swift files in place with swift-format.
set -euo pipefail
source "$(dirname "$0")/_docker.sh"
cd "$(repo_root)"

PATHS=(
    JutsuStudio JutsuCLI Packages/JutsuKit/Package.swift Packages/JutsuKit/Sources Packages/JutsuKit/Tests
    Packages/HiggsfieldKit/Package.swift Packages/HiggsfieldKit/Sources Packages/HiggsfieldKit/Tests
    Packages/ParakeetKit/Package.swift Packages/ParakeetKit/Sources
)
if swift_tool=$(swift_binary) && "$swift_tool" format --version >/dev/null 2>&1; then
    "$swift_tool" format format --in-place --recursive "${PATHS[@]}"
else
    in_docker "$SWIFT_IMAGE" -- swift format format --in-place --recursive "${PATHS[@]}"
fi
