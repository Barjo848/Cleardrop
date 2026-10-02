#!/usr/bin/env bash
# Copies dist/Cleardrop.app to /Applications, replacing a copy that is already there.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/Cleardrop.app"
DST="/Applications/Cleardrop.app"

if [[ ! -d "$SRC" ]]; then
  echo "Build first: ./scripts/build.sh"
  exit 1
fi

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "==> Installing Cleardrop $VER → $DST"
rm -rf "$DST"
cp -R "$SRC" "$DST"
touch "$DST"
echo "Installed. Open with: open -a Cleardrop"
