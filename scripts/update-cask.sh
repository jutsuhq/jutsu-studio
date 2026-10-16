#!/usr/bin/env bash
# Sets the version and sha256 of the Homebrew cask template to a release's.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/update-cask.sh <version> <sha256 | path to Jutsu-Studio-<version>.dmg.sha256>

Rewrites `version` and `sha256` in packaging/homebrew/jutsu-studio.rb (or $CASK) in place.
Copy the result into the tap; CONTRIBUTING.md#releasing has the steps.
USAGE
}

[[ $# -eq 2 ]] || { usage >&2; exit 1; }
version=$1
sha=$2
cask=${CASK:-"$(cd "$(dirname "$0")/.." && pwd)/packaging/homebrew/jutsu-studio.rb"}

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be X.Y.Z, got '$version'" >&2; exit 1; }
# A .sha256 file is shasum's output: "<hash>  <file name>".
if [[ -f $sha ]]; then
    read -r sha _ <"$sha"
fi
[[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "error: not a SHA-256: '$sha'" >&2; exit 1; }
[[ -f $cask ]] || { echo "error: no cask at $cask" >&2; exit 1; }

for key in version sha256; do
    count=$(grep -cE "^  $key \"[^\"]*\"$" "$cask" || true)
    [[ $count -eq 1 ]] || { echo "error: expected one '$key' line in $cask, found $count" >&2; exit 1; }
done

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed -E -e "s/^  version \"[^\"]*\"$/  version \"$version\"/" \
    -e "s/^  sha256 \"[^\"]*\"$/  sha256 \"$sha\"/" "$cask" >"$tmp"
cat "$tmp" >"$cask"
