#!/usr/bin/env bash
# Fails if tracked files carry things that do not belong in a public repository:
# files outside the expected layout, machine-specific paths, attribution trailers,
# development-diary phrasing, image metadata, or unexplained large files.
# Run by ./scripts/run_tests.sh, so CI and a local run check the same thing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C

SELF="scripts/audit_repo.sh"
status=0
fail() {
  echo "audit: $1"
  status=1
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "audit: not a git checkout, skipping"
  exit 0
fi

# Tracked files plus new files that are not ignored: what the next commit would contain.
FILES=()
while IFS= read -r file; do
  [[ -f "$file" ]] && FILES+=("$file")
done < <(git ls-files --cached --others --exclude-standard)

# 1. The repository has a fixed shape. Anything outside it is rejected, which covers
#    junk files, build output, editor state and tool-instruction files without naming them.
for file in "${FILES[@]}"; do
  case "$file" in
    .gitignore | LICENSE | README.md | CHANGELOG.md | SECURITY.md) ;;
    .github/workflows/*.yml) ;;
    docs/*.md) ;;
    Resources/Info.plist | Resources/Uninstaller-Info.plist | Resources/*.entitlements) ;;
    Resources/AppIcon.icns | Resources/icon_master.png) ;;
    Resources/Installer/distribution.xml | Resources/Installer/postinstall | Resources/Installer/*.txt) ;;
    scripts/*.sh) ;;
    Sources/Cleardrop/App/*.swift | Sources/Cleardrop/Engine/*.swift | Sources/Cleardrop/Uninstaller/*.swift) ;;
    Tests/*.swift | Tests/Fixtures/*.pdf) ;;
    *) fail "file outside the expected layout: $file" ;;
  esac
done

# 2. Content checks on text files.
check_text() {
  local label="$1" pattern="$2" hits
  hits="$(grep -InE -- "$pattern" "${TEXT_FILES[@]}" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    fail "$label:"
    echo "$hits" | sed 's/^/    /'
  fi
}

TEXT_FILES=()
for file in "${FILES[@]}"; do
  [[ "$file" == "$SELF" ]] && continue
  case "$file" in
    *.pdf | *.png | *.icns) continue ;;
  esac
  TEXT_FILES+=("$file")
done

if [[ ${#TEXT_FILES[@]} -gt 0 ]]; then
  check_text "absolute home path" '/(Users|home)/[A-Za-z0-9._-]+/'
  check_text "attribution trailer" '(Co-Authored-By:|Generated with )'
  check_text "development-diary phrasing" '(\bPR ?[0-9]+[a-z]?\b|\bStage ?[A-Z]?[0-9]|\bGate ?[0-9]|\bspike\b)'
fi

# 3. Committed images carry pixels only. PNG text and Exif chunks are metadata;
#    an .icns is a container of PNGs, so the same byte search applies.
for file in "${FILES[@]}"; do
  case "$file" in
    *.png | *.icns)
      if grep -aqE '(eXIf|tEXt|iTXt|zTXt)' "$file"; then
        fail "image metadata chunk in $file"
      fi
      ;;
  esac
done

# 4. Large files need a reason to be here.
for file in "${FILES[@]}"; do
  size="$(wc -c < "$file" | tr -d ' ')"
  if [[ "$size" -gt 262144 && "$file" != "Resources/AppIcon.icns" && "$file" != "Resources/icon_master.png" ]]; then
    fail "file over 256 KB: $file ($size bytes)"
  fi
done

if [[ "$status" -ne 0 ]]; then
  echo "audit: FAILED"
  exit 1
fi
echo "audit: ok (${#FILES[@]} files)"
