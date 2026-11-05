#!/bin/bash
# Renders images/og-image.png from og-image/og-image.html with headless Chrome, on
# the dark theme. Keep it a PNG, since crawler support for WebP is patchy.
set -euo pipefail

cd "$(dirname "$0")/.."
CHROME="${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if ! command -v "$CHROME" >/dev/null; then
    echo "Chrome not found at $CHROME; set CHROME_PATH." >&2
    exit 1
fi

# A throwaway profile, so this never touches a running browser.
profile=$(mktemp -d)
trap 'rm -rf "$profile"' EXIT

# Deleted first, so a failed render shows up as a missing file, not a stale preview.
rm -f images/og-image.png
"$CHROME" --headless=new --force-dark-mode --force-device-scale-factor=1 --hide-scrollbars \
    --user-data-dir="$profile" --window-size=1200,630 --virtual-time-budget=5000 \
    --screenshot="$PWD/images/og-image.png" "file://$PWD/og-image/og-image.html" 2>/dev/null

# Chrome exits 0 even when it can't write the screenshot, so check the file itself.
if [[ ! -s images/og-image.png ]]; then
    echo "Render failed: images/og-image.png was not written." >&2
    exit 1
fi
file images/og-image.png
