#!/usr/bin/env bash
# Usage: ./scripts/sign.sh <path to Cleardrop.app>
#
# Signs the app with the hardened runtime and the sandbox entitlements, then verifies the
# signature. Any failure is an error: an unsigned or half-signed app is not a build.
#
# The uninstaller inside the bundle is signed first and without the sandbox, because its
# job is to remove files the sandboxed app is not allowed to touch.
#
# By default the signature is ad hoc ("-"), which runs on the machine that built it.
# To sign for distribution, set CLEARDROP_SIGN_IDENTITY to the name of a Developer ID
# Application certificate in your keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "usage: $0 <path to Cleardrop.app>"
  exit 2
fi
APP="$1"
HELPER="$APP/Contents/Helpers/Cleardrop Uninstaller.app"
IDENTITY="${CLEARDROP_SIGN_IDENTITY:--}"

if [[ -d "$HELPER" ]]; then
  codesign --force --options runtime --sign "$IDENTITY" "$HELPER"
fi
codesign --force \
  --options runtime \
  --entitlements "$ROOT/Resources/Cleardrop.entitlements" \
  --sign "$IDENTITY" \
  "$APP"
codesign --verify --strict --deep "$APP"
echo "==> Signed $APP (identity: $IDENTITY)"
