#!/bin/zsh
# Runs Gradle for the Android app with its caches outside iCloud-synced ~/Documents.
# Usage: scripts/android.sh <gradle tasks…>     e.g. scripts/android.sh testDebugUnitTest assembleDebug
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../android" && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
CACHE="$HOME/Library/Caches/DocSnap-android/$(echo -n "$ROOT" | shasum | cut -c1-12)"
mkdir -p "$CACHE"
cd "$ROOT"
exec ./gradlew --project-cache-dir "$CACHE/gradle-project" "$@"
