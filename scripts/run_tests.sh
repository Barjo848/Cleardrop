#!/usr/bin/env bash
# Usage: ./scripts/run_tests.sh [--only <substring of test name>]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macosx14.0"
OUT="$ROOT/build/CleardropTests"

echo "==> Auditing repository"
bash "$ROOT/scripts/audit_repo.sh"

mkdir -p "$ROOT/build"

echo "==> Compiling test suite"
swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -O \
  -framework Foundation \
  -framework CryptoKit \
  -framework PDFKit \
  -framework AppKit \
  -framework Security \
  -lz \
  "$ROOT"/Tests/*.swift \
  "$ROOT"/Sources/Cleardrop/Engine/*.swift \
  "$ROOT/Sources/Cleardrop/Uninstaller/UninstallPlan.swift" \
  -o "$OUT"

if [[ "${CLEARDROP_BUILD_ONLY:-}" == "1" ]]; then
  exit 0
fi

echo "==> Running tests"
cd "$ROOT"
"$OUT" "$@"
