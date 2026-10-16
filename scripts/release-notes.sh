#!/usr/bin/env bash
# Writes the "What changed" part of a release's notes, from the commits between two refs, to stdout.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/release-notes.sh <since-ref> <until-ref> <version>

Prints markdown: what changed between the refs, then how to download and check the DMG.
<since-ref> may be empty for the first release; then every commit up to <until-ref> counts.

A release note is for somebody running the app, so commits that change the project rather than
the product are left out:
  - conventional-commit types test:, chore:, ci:, build:, refactor:, style:, docs: and
    fixes scoped to the pipeline: fix(ci):, fix(release):, fix(lint):
  - housekeeping by its shape: merges, reverts of reverts, formatting, lint, lock files,
    "Keep … compiling", "Bump …", "Update <file>.<ext>"
A conventional prefix on a commit that stays (feat(create): …) is dropped and the first letter
capitalised. The same subject appears once; a trailing "(#123)" is kept so it links to the PR.
USAGE
}

[[ $# -eq 3 ]] || { usage >&2; exit 1; }
since=$1
until=$2
version=$3

range=$until
[[ -n $since ]] && range="$since..$until"

skip_types='^(test|tests|chore|ci|build|refactor|style|docs|perf\(ci\))(\([^)]*\))?!?: '
skip_scoped_fix='^fix\((ci|release|lint|build|tests?)\)!?: '
skip_shape='^(Merge (pull request|branch|remote-tracking branch)|Revert "Revert|Bump |Format |Formatting|Fix (the )?lint|Lint |Keep .* compiling|Update [^ ]+\.(lock|resolved|yml|yaml|json|md)$)'

changes=$(git log --no-merges --format='%s' "$range" |
    grep -Ev "$skip_types" |
    grep -Ev "$skip_scoped_fix" |
    grep -Ev "$skip_shape" |
    sed -E 's/^[a-z]+(\([^)]*\))?!?: //' |
    awk '{ $0 = toupper(substr($0, 1, 1)) substr($0, 2) } !seen[$0]++' || true)

echo "## What changed"
echo
if [[ -n $changes ]]; then
    while IFS= read -r subject; do echo "- $subject"; done <<<"$changes"
else
    echo "- Maintenance only: no changes you can notice in the app."
fi
cat <<NOTES

## Download

Download \`Jutsu-Studio-$version.dmg\` below, open it and drag **Jutsu Studio** to Applications.
macOS 14 Sonoma or later, Apple silicon and Intel.

To check the download, compare its SHA-256 with \`Jutsu-Studio-$version.dmg.sha256\`:

\`\`\`bash
shasum -a 256 -c Jutsu-Studio-$version.dmg.sha256
\`\`\`
NOTES
