#!/bin/zsh
# Builds DocSnap and runs unit + UI tests on an iPhone simulator.
# Usage: scripts/test.sh            (all tests)
#        scripts/test.sh unit       (unit tests only)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null && xcodegen generate --quiet

# Prefer an iPhone 13 Pro simulator (the owner's phone), else any available iPhone.
DEST_ID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
devs=[x for k,v in d.items() if "iOS" in k for x in v]
pick=[x for x in devs if x["name"]=="iPhone 13 Pro"] or [x for x in devs if x["name"].startswith("iPhone")]
print(pick[-1]["udid"] if pick else "")')
if [[ -z "$DEST_ID" ]]; then echo "No iPhone simulator found" >&2; exit 1; fi

ONLY=()
if [[ "${1:-}" == "unit" ]]; then ONLY=(-only-testing:DocSnapTests); fi

# Build output lives outside the project: ~/Documents is synced to iCloud Drive, which would
# upload hundreds of MB of build products and create "… 2" conflict copies.
BUILD_DIR="$HOME/Library/Developer/Xcode/DerivedData/DocSnap-cli"
RESULT="$BUILD_DIR/TestResults.xcresult"
rm -rf "$RESULT"
# Capture xcodebuild's own exit status. (The old `... | grep ... || true; exit ${pipestatus[1]}`
# always exited 0: with pipefail the failing pipeline ran `true`, which reset pipestatus.)
set +e
xcodebuild test \
  -project DocSnap.xcodeproj -scheme DocSnap \
  -destination "id=$DEST_ID" \
  -derivedDataPath "$BUILD_DIR" \
  -resultBundlePath "$RESULT" \
  CODE_SIGNING_ALLOWED=NO \
  "${ONLY[@]}" 2>&1 | grep -E "error:|warning: .*DocSnap/|Test Case .*(passed|failed)|Executed|TEST (SUCCEEDED|FAILED)|\*\* "
STATUS=${pipestatus[1]}
set -e
exit $STATUS
