#!/usr/bin/env bash
# Assemble un spike en bundle .app signé.
#
# Pourquoi un bundle et pas un simple binaire : TCC (kTCCServiceAudioCapture)
# n'attribue de permission qu'à un client identifié par bundle ID. Un exécutable
# en ligne de commande nu n'obtient jamais de prompt — le tap renvoie du silence
# sans la moindre erreur.
set -euo pipefail

TARGET="${1:-SpikeTap}"
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

swift build --product "$TARGET"
BIN="$(swift build --product "$TARGET" --show-bin-path)/$TARGET"

APP="build/$TARGET.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "Spikes/$TARGET/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/$TARGET"

codesign --force \
	--sign "$IDENTITY" \
	--options runtime \
	--entitlements "Spikes/$TARGET/$TARGET.entitlements" \
	--timestamp=none \
	"$APP"

codesign --display --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Authority=Apple Dev" || true
echo "→ $APP/Contents/MacOS/$TARGET"
