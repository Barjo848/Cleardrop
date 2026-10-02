#!/usr/bin/env bash
# Builds dist/Cleardrop.app. Run ./scripts/run_tests.sh first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macosx14.0"
DIST="$ROOT/dist"
APP="$DIST/Cleardrop.app"
CONTENTS="$APP/Contents"
HELPER="$CONTENTS/Helpers/Cleardrop Uninstaller.app"

mkdir -p "$ROOT/build"

echo "==> Compiling Cleardrop"
swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -parse-as-library \
  -O \
  -framework Security \
  -lz \
  "$ROOT"/Sources/Cleardrop/App/*.swift \
  "$ROOT"/Sources/Cleardrop/Engine/*.swift \
  "$ROOT/Sources/Cleardrop/Uninstaller/UninstallPlan.swift" \
  -o "$ROOT/build/Cleardrop"

# The uninstaller is a separate program: the app is sandboxed and cannot remove itself.
echo "==> Compiling the uninstaller"
swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -parse-as-library \
  -O \
  "$ROOT"/Sources/Cleardrop/Uninstaller/*.swift \
  -o "$ROOT/build/CleardropUninstaller"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"
cp "$ROOT/build/Cleardrop" "$CONTENTS/MacOS/Cleardrop"
chmod +x "$CONTENTS/MacOS/Cleardrop"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
echo -n 'APPL????' > "$CONTENTS/PkgInfo"

cp "$ROOT/build/CleardropUninstaller" "$HELPER/Contents/MacOS/Cleardrop Uninstaller"
chmod +x "$HELPER/Contents/MacOS/Cleardrop Uninstaller"
cp "$ROOT/Resources/Uninstaller-Info.plist" "$HELPER/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$HELPER/Contents/Resources/AppIcon.icns"
echo -n 'APPL????' > "$HELPER/Contents/PkgInfo"

bash "$ROOT/scripts/sign.sh" "$APP"

echo "==> Built $APP"
