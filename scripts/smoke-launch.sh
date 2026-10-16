#!/usr/bin/env bash
# Launches a built Jutsu Studio once and fails unless it starts and quits cleanly. macOS only.
# release.sh runs this on the finished DMG before anything is published.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/smoke-launch.sh <Jutsu-Studio-X.Y.Z.dmg | Jutsu Studio.app>

Copies the app out of the DMG (or uses the .app as given), runs it with --smoke-test and
waits for it to report "launched" and exit 0. In smoke-test mode the app opens its library
and first window but never starts the queue or touches the network, so this is safe to run
on a Mac with real jobs in the library.

  SMOKE_TIMEOUT   Seconds to wait for the app to quit (default 60).
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

[[ $# -eq 1 && $1 != -h && $1 != --help ]] || { usage; [[ $# -eq 1 ]] && exit 0; exit 1; }
[[ $(uname -s) == Darwin ]] || die "the smoke test launches a macOS app; run it on a Mac."
target=$1
timeout=${SMOKE_TIMEOUT:-60}
[[ -e $target ]] || die "no such file: $target"

# Resolved: mktemp gives /var/folders/…, but `mount` lists the image under /private/var/folders/….
work=$(cd "$(mktemp -d)" && pwd -P)
mount="$work/mount"
cleanup() {
    if [[ -d $mount ]] && mount | grep -q " on $mount "; then hdiutil detach -quiet -force "$mount" || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

case $target in
    *.dmg)
        mkdir "$mount"
        hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$mount" "$target"
        source_app=$(find "$mount" -maxdepth 1 -name '*.app' -print -quit)
        [[ -n $source_app ]] || die "no .app in $target"
        # A copy, as an installed app would be: running from a read-only image triggers App Translocation.
        app="$work/${source_app##*/}"
        ditto "$source_app" "$app"
        ;;
    *.app) app=$target ;;
    *) die "expected a .dmg or an .app: $target" ;;
esac

executable=$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist")
binary="$app/Contents/MacOS/$executable"
[[ -x $binary ]] || die "no executable at $binary"

log="$work/launch.log"
touch "$work/started"
"$binary" --smoke-test >"$log" 2>&1 &
pid=$!

for ((elapsed = 0; elapsed < timeout; elapsed++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
done
if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    cat "$log" >&2
    die "the app was still running after ${timeout}s (a modal alert at launch, or a hang)."
fi

status=0
wait "$pid" || status=$?
if [[ $status -ne 0 ]] || ! grep -q '^smoke-test: launched$' "$log"; then
    cat "$log" >&2
    # The crash report, if launching crashed it; written next to the user's other diagnostic reports.
    report=$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name "${executable}*" -newer "$work/started" \
        -print 2>/dev/null | head -n 1 || true)
    [[ -n $report ]] && { echo "crash report: $report" >&2; head -n 60 "$report" >&2; }
    die "the app exited with status $status without reporting a clean launch."
fi
echo "launched and quit cleanly ($(lipo -archs "$binary"), $((elapsed)) s)"
