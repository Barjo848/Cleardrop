#!/usr/bin/env bash
# Usage: ./scripts/corpus_check.sh <directory>
#
# Runs the engine over every PDF under <directory> and prints what happened to each:
# cleaned, refused (encrypted, signed), unsupported, or damaged, with the reason.
# Use it to try Cleardrop on your own files. Everything happens in memory: no file is
# written, copied or changed, and nothing leaves this machine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "usage: $0 <directory>"
  exit 2
fi
TARGET="$(cd "$1" && pwd)"

echo "Building the checker (about a minute, no output while it runs)…"
CLEARDROP_BUILD_ONLY=1 bash "$ROOT/scripts/run_tests.sh" >/dev/null
cd "$ROOT"
"$ROOT/build/CleardropTests" --corpus "$TARGET"
