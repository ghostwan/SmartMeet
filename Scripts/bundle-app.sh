#!/usr/bin/env bash
# Assemble et signe SmartMeet.app.
#
# La signature utilise une identité stable : TCC lie les autorisations (micro,
# capture audio système) à la signature du bundle. Re-signer en ad-hoc à chaque
# build ferait révoquer l'autorisation à chaque fois.
set -euo pipefail

CONFIGURATION="${SMARTMEET_CONFIGURATION:-debug}"
# TCC lie les autorisations à la signature du bundle : l'identité doit rester stable
# d'un build à l'autre, sinon macOS redemande micro et capture audio à chaque fois.
IDENTITY="${SMARTMEET_SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
	awk -F'"' '/[0-9]+\)/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
	echo "Aucune identité de signature trouvée. Définis SMARTMEET_SIGN_IDENTITY." >&2
	exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build --product SmartMeet --configuration "$CONFIGURATION"
BIN="$(swift build --product SmartMeet --configuration "$CONFIGURATION" --show-bin-path)/SmartMeet"

APP="build/SmartMeet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Sources/SmartMeetApp/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/SmartMeet"

# Icône : régénérée depuis le dessin vectoriel, jamais commitée en binaire.
swift Scripts/make-icon.swift >/dev/null
iconutil -c icns build/SmartMeet.iconset -o "$APP/Contents/Resources/SmartMeet.icns"

codesign --force \
	--sign "$IDENTITY" \
	--options runtime \
	--entitlements Sources/SmartMeetApp/SmartMeet.entitlements \
	--timestamp=none \
	"$APP"

codesign --verify --strict "$APP"
echo "✅ $APP signé $(codesign -dv "$APP" 2>&1 | awk -F= '/^Identifier/ {print $2}')"
echo "   lancement : open $APP"
