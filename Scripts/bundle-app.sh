#!/usr/bin/env bash
# Assembles and signs SmartMeet.app.
#
# The signature must use a stable identity: TCC ties permissions (microphone,
# system audio capture) to the bundle's signature. Re-signing ad hoc on every
# build would revoke the permission every time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${SMARTMEET_CONFIGURATION:-debug}"

source Scripts/resolve-sign-identity.sh
resolve_sign_identity

swift build --product SmartMeet --configuration "$CONFIGURATION"
BIN="$(swift build --product SmartMeet --configuration "$CONFIGURATION" --show-bin-path)/SmartMeet"

APP="build/SmartMeet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Sources/SmartMeetApp/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/SmartMeet"

# Localization: plain .lproj folders (no String Catalog / SPM resource bundle
# here — the bundle is assembled by hand, so Bundle.main resolves them
# directly without any extra resource-bundle plumbing).
cp -R Sources/SmartMeetApp/Resources/*.lproj "$APP/Contents/Resources/"

# Icon: regenerated from the vector artwork, never committed as a binary.
swift Scripts/make-icon.swift >/dev/null
iconutil -c icns build/SmartMeet.iconset -o "$APP/Contents/Resources/SmartMeet.icns"

codesign --force \
	--sign "$IDENTITY" \
	--options runtime \
	--entitlements Sources/SmartMeetApp/SmartMeet.entitlements \
	--timestamp=none \
	"$APP"

codesign --verify --strict "$APP"
echo "✅ $APP signed $(codesign -dv "$APP" 2>&1 | awk -F= '/^Identifier/ {print $2}')"
echo "   launch: open $APP"
