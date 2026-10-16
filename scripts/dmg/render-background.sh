#!/usr/bin/env bash
# Renders scripts/dmg/background.html to background.png and background@2x.png with headless Google Chrome.
# dmgbuild combines the two into one HiDPI background. Run after editing the HTML and commit the PNGs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
[[ -x $CHROME ]] || { echo "error: Google Chrome not found; set CHROME to its binary." >&2; exit 1; }

PROFILE=$(mktemp -d)
trap 'rm -rf "$PROFILE"' EXIT
for scale in 1 2; do
    out=background.png
    ((scale == 2)) && out=background@2x.png
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$PROFILE" \
        --allow-file-access-from-files --window-size=680,420 --force-device-scale-factor=$scale \
        --virtual-time-budget=2000 --screenshot="$PWD/$out" "file://$PWD/background.html" 2>/dev/null
    echo "$out: $(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/ {printf "%s ", $2}')"
done
