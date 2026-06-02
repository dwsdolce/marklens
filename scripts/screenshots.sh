#!/usr/bin/env bash
# Capture App Store screenshots from iPhone + iPad simulators and a macOS
# launch of Marklens.app. Output goes into ./screenshots/{iphone,ipad,mac}/.
#
# Usage:
#   scripts/screenshots.sh           # capture everything
#   scripts/screenshots.sh iphone    # only iPhone
#   scripts/screenshots.sh ipad      # only iPad
#   scripts/screenshots.sh mac       # only Mac
#
# Output sizes (matched to App Store Connect requirements):
#   iPhone 17 Pro  → 1320 × 2868   (6.9" — accepted as the iPhone reference)
#   iPad Pro 13"   → 2064 × 2752   (M5 — accepted as the iPad reference)
#   Mac            → 2880 × 1800   (max accepted size)
#
# Sims expected:
#   iPhone 17 Pro       (auto-discovered or override via $IPHONE_UDID)
#   iPad Pro 13-inch (M5) (auto-discovered or override via $IPAD_UDID)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

OUT="$REPO_ROOT/screenshots"
mkdir -p "$OUT/iphone" "$OUT/ipad" "$OUT/mac"

# Make sure xcrun/simctl resolves to a full Xcode install, not Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

BUNDLE_ID="solutions.ddj.marklens"
APP_PATH="${APP_PATH:-$HOME/Library/Developer/Xcode/DerivedData/Marklens-dmfjgxndequlcfadmpakgtgbyumg/Build/Products/Debug-iphonesimulator/Marklens.app}"

WHICH="${1:-all}"

# -- helpers -----------------------------------------------------------

# Look up a simulator UDID by device-type name. Returns the FIRST match.
sim_udid_for() {
    local name="$1"
    xcrun simctl list devices available -j \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devs in data['devices'].items():
    for d in devs:
        if d['name'] == sys.argv[1]:
            print(d['udid']); sys.exit(0)
" "$name"
}

ensure_booted() {
    local udid="$1"
    local state
    state=$(xcrun simctl list devices -j \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devs in data['devices'].items():
    for d in devs:
        if d['udid'] == sys.argv[1]:
            print(d['state']); sys.exit(0)
" "$udid")
    if [[ "$state" != "Booted" ]]; then
        echo "  → booting $udid"
        xcrun simctl boot "$udid"
        xcrun simctl bootstatus "$udid" >/dev/null
    fi
}

build_simulator_app_if_missing() {
    if [[ ! -d "$APP_PATH" ]]; then
        echo "→ Building Marklens for iOS Simulator (first run)…"
        xcodebuild -project Marklens.xcodeproj -scheme Marklens \
            -destination 'generic/platform=iOS Simulator' \
            -configuration Debug build >/dev/null
    fi
}

populate_samples() {
    local udid="$1"
    local container
    container=$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data 2>/dev/null || true)
    if [[ -z "$container" ]]; then return; fi
    mkdir -p "$container/Documents"
    cp Samples/*.md "$container/Documents/" 2>/dev/null || true
}

screenshot_sim() {
    local udid="$1" out="$2"
    xcrun simctl io "$udid" screenshot --type=png "$out" >/dev/null
    echo "  ✓ $out"
}

# -- iPhone ------------------------------------------------------------

capture_iphone() {
    local udid
    udid="${IPHONE_UDID:-$(sim_udid_for 'iPhone 17 Pro')}"
    if [[ -z "$udid" ]]; then
        echo "✗ iPhone 17 Pro simulator not found. Install via Xcode → Settings → Components." >&2
        return 1
    fi
    echo "📱 iPhone 17 Pro ($udid)"
    ensure_booted "$udid"
    build_simulator_app_if_missing
    xcrun simctl install "$udid" "$APP_PATH" >/dev/null
    populate_samples "$udid"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
    sleep 2

    screenshot_sim "$udid" "$OUT/iphone/01-launch.png"

    cat <<EOF

   Next: manually open each sample in the simulator and re-run with
   --capture-only to grab a doc screenshot, or use the per-file commands:

     xcrun simctl io $udid screenshot $OUT/iphone/02-welcome.png
     xcrun simctl io $udid screenshot $OUT/iphone/03-code.png
     xcrun simctl io $udid screenshot $OUT/iphone/04-diagrams.png

EOF
}

# -- iPad --------------------------------------------------------------

capture_ipad() {
    local udid
    udid="${IPAD_UDID:-$(sim_udid_for 'iPad Pro 13-inch (M5)')}"
    if [[ -z "$udid" ]]; then
        echo "✗ iPad Pro 13-inch (M5) not found. Install via Xcode → Settings → Components." >&2
        return 1
    fi
    echo "📱 iPad Pro 13-inch (M5) ($udid)"
    ensure_booted "$udid"
    build_simulator_app_if_missing
    xcrun simctl install "$udid" "$APP_PATH" >/dev/null
    populate_samples "$udid"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
    sleep 2

    screenshot_sim "$udid" "$OUT/ipad/01-launch.png"

    cat <<EOF

   Next: manually open each sample in the simulator and grab additional
   screenshots:

     xcrun simctl io $udid screenshot $OUT/ipad/02-welcome.png
     xcrun simctl io $udid screenshot $OUT/ipad/03-code.png
     xcrun simctl io $udid screenshot $OUT/ipad/04-diagrams.png

EOF
}

# -- Mac ---------------------------------------------------------------

capture_mac() {
    echo "🖥  Mac"
    if [[ ! -d /Applications/Marklens.app ]]; then
        echo "✗ /Applications/Marklens.app not installed."
        echo "  Run: xcodebuild -project Marklens.xcodeproj -scheme Marklens -destination 'platform=macOS' -configuration Release build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO"
        echo "  Then: cp -R <DerivedData>/Marklens.app /Applications/"
        return 1
    fi

    # Pre-resize the window via defaults — Marklens uses standard SwiftUI
    # window restoration, so kill any previous saved state first.
    osascript -e 'tell application "Marklens" to quit' 2>/dev/null || true
    defaults delete solutions.ddj.marklens NSWindow.FrameAutosaveName 2>/dev/null || true

    open -a Marklens "$REPO_ROOT/Samples/welcome.md"
    sleep 3

    # Resize the front window to 2880×1800 if possible (requires accessibility
    # permissions for Terminal/Ghostty in System Settings → Privacy & Security).
    osascript <<'AS' 2>/dev/null || echo "  (couldn't auto-resize window — grant Accessibility access if you want exact 2880×1800)"
tell application "Marklens" to activate
delay 0.5
tell application "System Events"
    tell process "Marklens"
        set position of window 1 to {0, 0}
        set size of window 1 to {2880, 1800}
    end tell
end tell
AS

    sleep 1
    # Capture frontmost Marklens window only (skipping menu bar / Dock).
    local win_id
    win_id=$(/usr/sbin/screencapture -l$(GetWindowID Marklens 2>/dev/null || true) "$OUT/mac/01-welcome.png" 2>&1 | head -1 || true)
    # GetWindowID may not be installed; fall back to interactive window capture.
    if [[ ! -f "$OUT/mac/01-welcome.png" ]]; then
        echo "  → Click the Marklens window when prompted (or install: brew install rsync GetWindowID)"
        /usr/sbin/screencapture -W "$OUT/mac/01-welcome.png"
    fi
    echo "  ✓ $OUT/mac/01-welcome.png"

    cat <<EOF

   Next: open code-showcase.md and diagrams.md in Marklens and re-run with
   --capture-only, or:

     screencapture -W $OUT/mac/02-code.png        # then click Marklens window
     screencapture -W $OUT/mac/03-diagrams.png

EOF
}

# -- entry -------------------------------------------------------------

case "$WHICH" in
    iphone) capture_iphone ;;
    ipad)   capture_ipad ;;
    mac)    capture_mac ;;
    all)    capture_iphone; capture_ipad; capture_mac ;;
    *)      echo "Usage: $0 [iphone|ipad|mac|all]" >&2; exit 1 ;;
esac

echo ""
echo "Done. Screenshots in $OUT/"
