#!/usr/bin/env bash
# The same full-history scan locally and in CI. CI installs a checksum-verified scanner, never executes a remote script.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v gitleaks >/dev/null; then
    exec gitleaks git --redact --log-opts=--all
fi
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
    { echo 'Install gitleaks to run the secret scan locally.' >&2; exit 1; }
version=8.30.1
checksum=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
curl -fsSL --retry 3 -o "$scratch/gitleaks.tar.gz" \
    "https://github.com/gitleaks/gitleaks/releases/download/v$version/gitleaks_${version}_linux_x64.tar.gz"
printf '%s  %s\n' "$checksum" "$scratch/gitleaks.tar.gz" | sha256sum --check --status
tar -xzf "$scratch/gitleaks.tar.gz" -C "$scratch" gitleaks
"$scratch/gitleaks" git --redact --log-opts=--all
