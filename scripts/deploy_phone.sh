#!/bin/zsh
# Builds DocSnap signed with the owner's Personal Team and installs it on their iPhone —
# over USB or Wi‑Fi (same network, phone unlocked). Also refreshes the 7-day free-signing expiry.
# Usage: scripts/deploy_phone.sh [device-udid]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Device: argument, else DOCSNAP_DEVICE_ID from Config/Local.xcconfig (kept out of the public repo).
DEVICE="${1:-$(sed -n 's/^DOCSNAP_DEVICE_ID *= *//p' "$ROOT/Config/Local.xcconfig" 2>/dev/null | tr -d ' ')}"
[[ -n "$DEVICE" ]] || { echo "Set DOCSNAP_DEVICE_ID in Config/Local.xcconfig or pass the UDID." >&2; exit 1; }
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/DocSnap-device"
APP="$DERIVED/Build/Products/Debug-iphoneos/DocSnap.app"

cd "$ROOT"
[[ -f Config/Local.xcconfig ]] || { echo "Config/Local.xcconfig is missing (Team ID, server URL, app token)." >&2; exit 1; }

state=$(xcrun devicectl list devices 2>/dev/null | grep -F "$DEVICE" || true)
if [[ -z "$state" || "$state" == *unavailable* ]]; then
  echo "iPhone $DEVICE isn't reachable. Unlock it and connect it by cable or put it on the same Wi‑Fi as this Mac." >&2
  exit 2
fi

command -v xcodegen >/dev/null && xcodegen generate --quiet
echo "Building…"
set +e
xcodebuild build -project DocSnap.xcodeproj -scheme DocSnap -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" 
rc=${pipestatus[1]}
set -e
(( rc == 0 )) || { echo "Build failed." >&2; exit $rc; }

echo "Installing on the iPhone…"
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "App installed|bundleID" || true
xcrun devicectl device process launch --device "$DEVICE" com.vinhhoang.docsnap >/dev/null 2>&1 \
  && echo "Launched DocSnap on the iPhone." \
  || echo "Installed. (Couldn't auto-launch — open DocSnap on the phone.)"
