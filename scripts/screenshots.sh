#!/bin/bash
# Capture the DESIGN.md §8 review screenshots from fixture mode.
#
#   scripts/screenshots.sh <out-dir> [scene ...]
#
# Writes <out-dir>/{light,dark}/NN-scene.png for each scene (all of them when
# none are named). Needs a Debug build installed on the simulator:
#
#   xcodebuild build -scheme AriaSoftphone -destination "id=$SIM" -derivedDataPath build/dd
#   xcrun simctl install "$SIM" build/dd/Build/Products/Debug-iphonesimulator/AriaSoftphone.app
#
# Environment:
#   SIM         simulator UDID or name (default: "iPhone 18 Pro Max")
#   APPEARANCES "light dark" (default) or one of them
#   CONTENT_SIZE  a UIContentSizeCategory for large-text runs, e.g.
#               accessibility-extra-extra-extra-large; restored afterwards
#   SETTLE      seconds to wait after launch (default 3)
#   APP         the .app to install (default: the build/dd Debug product)

set -euo pipefail

OUT="${1:?usage: $0 <out-dir> [scene ...]}"
shift
SCENES=("$@")
if [ ${#SCENES[@]} -eq 0 ]; then
    SCENES=(onboarding dialer dialer-number incoming-call in-call in-call-two-calls
            history contacts voicemail voicemail-playing settings forwarding connection-sheet)
fi
SIM="${SIM:-iPhone 18 Pro Max}"
APPEARANCES="${APPEARANCES:-light dark}"
SETTLE="${SETTLE:-3}"
BUNDLE=com.solutions5060.aria
APP="${APP:-$(dirname "$0")/../build/dd/Build/Products/Debug-iphonesimulator/AriaSoftphone.app}"

number() {
    local i=1
    for s in onboarding dialer dialer-number incoming-call in-call in-call-two-calls \
             history contacts voicemail voicemail-playing settings forwarding connection-sheet; do
        if [ "$s" = "$1" ]; then printf "%02d" $i; return; fi
        i=$((i + 1))
    done
    echo "unknown scene: $1" >&2
    exit 1
}

# A fresh boot: SpringBoard alerts can outlive an uninstall and land in a shot.
# Set NO_REBOOT=1 to skip.
if [ -z "${NO_REBOOT:-}" ]; then
    xcrun simctl shutdown "$SIM" 2>/dev/null || true
fi
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true
xcrun simctl install "$SIM" "$APP"
xcrun simctl status_bar "$SIM" override --time 9:41 --dataNetwork wifi \
    --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3

# No permission alerts over the shots.
for service in contacts microphone; do
    xcrun simctl privacy "$SIM" grant "$service" "$BUNDLE" 2>/dev/null || true
done

if [ -n "${CONTENT_SIZE:-}" ]; then
    xcrun simctl ui "$SIM" content_size "$CONTENT_SIZE"
fi

for appearance in $APPEARANCES; do
    mkdir -p "$OUT/$appearance"
    xcrun simctl ui "$SIM" appearance "$appearance"
    for scene in "${SCENES[@]}"; do
        file="$OUT/$appearance/$(number "$scene")-$scene.png"
        xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
        xcrun simctl launch "$SIM" "$BUNDLE" -ScreenshotMode -FixtureScene "$scene" >/dev/null
        sleep "$SETTLE"
        xcrun simctl io "$SIM" screenshot --type=png "$file" >/dev/null 2>&1
        echo "$file"
    done
done

xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
if [ -n "${CONTENT_SIZE:-}" ]; then
    xcrun simctl ui "$SIM" content_size large
fi
