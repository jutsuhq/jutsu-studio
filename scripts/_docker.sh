# Shared helpers: run a tool natively when installed, otherwise in Docker.
# Sourced by the other scripts; works on macOS, Linux and Git Bash on Windows.

SWIFT_IMAGE="swift:6.4.1"
SWIFTLINT_IMAGE="ghcr.io/realm/swiftlint:0.65.1"

repo_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

swift_binary() {
    if command -v swift >/dev/null && swift --version >/dev/null 2>&1; then
        command -v swift
    elif command -v xcrun >/dev/null; then
        xcrun --find swift
    else
        return 1
    fi
}

# Usage: in_docker IMAGE [docker run options...] -- COMMAND...
# Docker on Windows needs a Windows path for the volume and no MSYS path rewriting.
in_docker() {
    local image=$1; shift
    local opts=()
    while [[ $# -gt 0 && $1 != "--" ]]; do opts+=("$1"); shift; done
    shift
    local src
    src=$(pwd -W 2>/dev/null || pwd)
    MSYS_NO_PATHCONV=1 docker run --rm -v "$src:/src" -w /src "${opts[@]}" "$image" "$@"
}
