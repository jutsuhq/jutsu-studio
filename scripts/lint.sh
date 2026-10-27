#!/usr/bin/env bash
# Lint: swift-format (formatting), SwiftLint (semantic rules), architecture import rules.
set -euo pipefail
source "$(dirname "$0")/_docker.sh"
cd "$(repo_root)"

PATHS=(
    JutsuStudio JutsuCLI Packages/JutsuKit/Package.swift Packages/JutsuKit/Sources Packages/JutsuKit/Tests
    Packages/HiggsfieldKit/Package.swift Packages/HiggsfieldKit/Sources Packages/HiggsfieldKit/Tests
    Packages/ParakeetKit/Package.swift Packages/ParakeetKit/Sources
)

echo "› swift-format"
if swift_tool=$(swift_binary) && "$swift_tool" format --version >/dev/null 2>&1; then
    "$swift_tool" format lint --strict --recursive "${PATHS[@]}"
else
    in_docker "$SWIFT_IMAGE" -- swift format lint --strict --recursive "${PATHS[@]}"
fi

echo "› SwiftLint"
if command -v swiftlint >/dev/null; then
    swiftlint lint --strict --quiet
else
    in_docker "$SWIFTLINT_IMAGE" -- swiftlint lint --strict --quiet
fi

echo "› architecture"
scripts/check-architecture.sh

echo "› log privacy"
scripts/check-log-privacy.sh

echo "› string catalogs"
scripts/check-localization.sh
