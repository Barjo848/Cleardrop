#!/usr/bin/env bash
# Builds dist/Cleardrop-<version>.pkg, a standard macOS installer for dist/Cleardrop.app.
# Run ./scripts/build.sh first.
#
# The installer shows a welcome page, the licence, a choice of installing for all users or
# only for you, progress, and a summary; it then opens Cleardrop.
#
# By default the package is unsigned, so macOS warns before opening it on another Mac.
# To sign it, set CLEARDROP_INSTALLER_IDENTITY to the name of a Developer ID Installer
# certificate in your keychain. Notarization is a separate, manual step (see README).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Cleardrop.app"
WORK="$ROOT/build/package"
IDENTIFIER="io.github.barjo848.Cleardrop.pkg"

if [[ ! -d "$APP" ]]; then
  echo "Build first: ./scripts/build.sh"
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="$ROOT/dist/Cleardrop-$VERSION.pkg"

rm -rf "$WORK"
mkdir -p "$WORK/root" "$WORK/scripts" "$WORK/resources"
# ditto keeps the code signature intact and leaves out Finder metadata.
ditto --norsrc --noextattr "$APP" "$WORK/root/Cleardrop.app"
cp "$ROOT/Resources/Installer/postinstall" "$WORK/scripts/postinstall"
chmod +x "$WORK/scripts/postinstall"

sed "s/@VERSION@/$VERSION/g" "$ROOT/Resources/Installer/welcome.txt" > "$WORK/resources/welcome.txt"
cp "$ROOT/Resources/Installer/conclusion.txt" "$WORK/resources/conclusion.txt"
cp "$ROOT/LICENSE" "$WORK/resources/license.txt"
sed "s/@VERSION@/$VERSION/g" "$ROOT/Resources/Installer/distribution.xml" > "$WORK/distribution.xml"

# Not relocatable: otherwise the installer "updates" whatever copy of Cleardrop it finds on
# the disk, such as a build folder, instead of installing where the person chose.
cat > "$WORK/component.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict>
		<key>RootRelativeBundlePath</key>
		<string>Cleardrop.app</string>
		<key>BundleIsRelocatable</key>
		<false/>
		<key>BundleIsVersionChecked</key>
		<false/>
		<key>BundleHasStrictIdentifier</key>
		<true/>
		<key>BundleOverwriteAction</key>
		<string>upgrade</string>
		<key>ChildBundles</key>
		<array>
			<dict>
				<key>RootRelativeBundlePath</key>
				<string>Cleardrop.app/Contents/Helpers/Cleardrop Uninstaller.app</string>
				<key>BundleIsRelocatable</key>
				<false/>
				<key>BundleIsVersionChecked</key>
				<false/>
				<key>BundleHasStrictIdentifier</key>
				<true/>
				<key>BundleOverwriteAction</key>
				<string>upgrade</string>
			</dict>
		</array>
	</dict>
</array>
</plist>
PLIST

echo "==> Building component package"
pkgbuild \
  --root "$WORK/root" \
  --component-plist "$WORK/component.plist" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/Applications" \
  --scripts "$WORK/scripts" \
  "$WORK/Cleardrop-component.pkg" >/dev/null

echo "==> Building installer"
rm -f "$OUT"
SIGN_ARGS=()
if [[ -n "${CLEARDROP_INSTALLER_IDENTITY:-}" ]]; then
  SIGN_ARGS=(--sign "$CLEARDROP_INSTALLER_IDENTITY")
fi
productbuild \
  --distribution "$WORK/distribution.xml" \
  --package-path "$WORK" \
  --resources "$WORK/resources" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  "$OUT" >/dev/null

echo "==> Built $OUT"
if [[ -z "${CLEARDROP_INSTALLER_IDENTITY:-}" ]]; then
  echo "    Unsigned: macOS will warn before opening it on another Mac."
fi
