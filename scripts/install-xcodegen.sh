#!/usr/bin/env bash
# Installs the pinned XcodeGen release into DIR/xcodegen and prints its bin directory. macOS only.
# CI and the release workflow use this instead of an unpinned `brew install xcodegen`.
set -euo pipefail

VERSION=2.46.0
SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806

die() { echo "error: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: scripts/install-xcodegen.sh DIR"
dir=$1
mkdir -p "$dir"
zip="$dir/xcodegen-$VERSION.zip"

curl -fsSL --retry 3 -o "$zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
echo "$SHA256  $zip" | shasum -a 256 -c - >/dev/null || die "checksum mismatch for XcodeGen $VERSION."
rm -rf "$dir/xcodegen"
# The binary finds its setting presets in ../share/xcodegen, so the archive is unpacked as is.
unzip -q "$zip" -d "$dir"
rm -f "$zip"
installed=$("$dir/xcodegen/bin/xcodegen" --version)
[[ $installed == *"$VERSION"* ]] || die "unpacked XcodeGen reports '$installed', expected $VERSION."
echo "$dir/xcodegen/bin"
