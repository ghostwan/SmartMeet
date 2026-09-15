#!/usr/bin/env bash
# Assembles a spike into a signed .app bundle.
#
# Why a bundle and not a plain binary: TCC (kTCCServiceAudioCapture) only
# grants permission to a client identified by bundle ID. A bare command-line
# executable never gets a prompt — the tap silently returns silence instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-SpikeTap}"

source Scripts/resolve-sign-identity.sh
resolve_sign_identity

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
