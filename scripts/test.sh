#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_docker.sh"
cd "$(repo_root)"

usage() {
    cat <<'HELP'
Usage: scripts/test.sh [fast|all|kit|app|media] [swift test options]

  fast   Both packages, excluding macOS media, persistence and Keychain tests (default).
  all    Every test in both packages; use before a PR.
  kit    HiggsfieldKit only.
  app    JutsuKit only; use with --filter to focus on a suite or case.
  media  AVFoundation tests only (macOS).

Examples:
  scripts/test.sh app --filter PagedFeedTests
  scripts/test.sh kit --skip-build
HELP
}

mode=fast
if [[ $# -gt 0 && $1 != -* ]]; then mode=$1; shift; fi
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
case "$mode" in fast|all|kit|app|media) ;; *) usage >&2; exit 2 ;; esac
swift_tool=$(swift_binary) || { echo "Swift is unavailable. Install Swift or use scripts/test-linux.sh." >&2; exit 1; }

run_tests() {
    local package=$1; shift
    echo "› $package"
    "$swift_tool" test --disable-xctest --jobs 4 --package-path "Packages/$package" "$@"
}

case "$mode" in
    fast)
        run_tests HiggsfieldKit "$@"
        run_tests JutsuKit --skip 'MediaKitTests|PersistenceTests|SecretsTests' "$@"
        ;;
    all) run_tests HiggsfieldKit "$@"; run_tests JutsuKit "$@" ;;
    kit) run_tests HiggsfieldKit "$@" ;;
    app) run_tests JutsuKit "$@" ;;
    media) run_tests JutsuKit --filter MediaKitTests "$@" ;;
esac
