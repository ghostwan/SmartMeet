#!/usr/bin/env bash
# Builds SmartMeet.app, packages it into a .dmg, and publishes a GitHub release.
#
#     Scripts/release.sh v0.1.0
#     Scripts/release.sh v0.1.0 --draft
#
# Distribution outside the App Store: without a (paid) Developer ID
# certificate or notarization, the .dmg isn't recognized by Gatekeeper. The
# release therefore includes a note explaining how to work around the
# warning (right-click → Open, or `xattr -cr`). See TODO.md to eventually
# move to notarized distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
DRAFT=false
[ "${2:-}" = "--draft" ] && DRAFT=true

if [ -z "$VERSION" ]; then
	echo "Usage: Scripts/release.sh vX.Y.Z [--draft]" >&2
	exit 1
fi
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
	echo "The tag should look like v0.1.0 (got: $VERSION)." >&2
	exit 1
fi
if git rev-parse "$VERSION" >/dev/null 2>&1; then
	echo "Tag $VERSION already exists." >&2
	exit 1
fi

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() {
	printf '\033[31m✗ %s\033[0m\n' "$1" >&2
	exit 1
}

VERSION_NUMBER="${VERSION#v}"

step "Version bump"
# VERSION is the single source of truth `bundle-app.sh` reads to stamp
# CFBundleShortVersionString: it must be updated, committed and pushed
# *before* bundling below, or the build would ship under the previous
# version number.
echo "$VERSION_NUMBER" >VERSION

# Folds this release's RELEASE_NOTES.md ("Unreleased") content into
# CHANGELOG.md under its own dated heading, right after the file's leading
# comment and before whatever was already there — CHANGELOG.md itself is
# never cleared (see its own header), unlike RELEASE_NOTES.md below.
if [ -f RELEASE_NOTES.md ] && [ -f CHANGELOG.md ]; then
	ENTRY="$(mktemp)"
	{
		echo "## ${VERSION_NUMBER} — $(date +%Y-%m-%d)"
		echo
		sed -n '/^## Unreleased/,$p' RELEASE_NOTES.md | tail -n +2
	} >"$ENTRY"

	FIRST_HEADING_LINE="$(grep -n '^## ' CHANGELOG.md | head -1 | cut -d: -f1)"
	TMP_CHANGELOG="$(mktemp)"
	head -n "$((FIRST_HEADING_LINE - 1))" CHANGELOG.md >"$TMP_CHANGELOG"
	cat "$ENTRY" >>"$TMP_CHANGELOG"
	echo >>"$TMP_CHANGELOG"
	tail -n "+${FIRST_HEADING_LINE}" CHANGELOG.md >>"$TMP_CHANGELOG"
	mv "$TMP_CHANGELOG" CHANGELOG.md
	rm -f "$ENTRY"
fi

if [ "$DRAFT" = false ]; then
	git add VERSION CHANGELOG.md
	git commit -m "Bump version to ${VERSION_NUMBER}"
	git push
	echo "✓ VERSION and CHANGELOG.md updated and pushed"
else
	echo "✓ VERSION and CHANGELOG.md updated locally (draft: not committed)"
fi

step "Signed bundle (release)"
SMARTMEET_CONFIGURATION=release ./Scripts/bundle-app.sh || fail "Bundle assembly failed."
codesign --verify --strict build/SmartMeet.app || fail "Invalid signature."

step "Disk image"
DMG="build/SmartMeet-${VERSION#v}.dmg"
rm -f "$DMG"
swift Scripts/make-dmg-background.swift >/dev/null || fail "Failed to generate the .dmg background."
if command -v create-dmg >/dev/null 2>&1; then
	# create-dmg returns a non-zero exit code even on success (Finder sometimes
	# takes a moment to write the window metadata): judge success by the
	# presence of the file, not by the exit code.
	create-dmg \
		--volname "SmartMeet" \
		--background "build/dmg-background.png" \
		--window-size 660 400 \
		--icon-size 128 \
		--icon "SmartMeet.app" 180 190 \
		--hide-extension "SmartMeet.app" \
		--app-drop-link 480 190 \
		--no-internet-enable \
		"$DMG" \
		"build/SmartMeet.app" || true
	[ -f "$DMG" ] || fail "Failed to create the .dmg (create-dmg)."
else
	echo "create-dmg not found (brew install create-dmg) — basic .dmg without a visual drag-and-drop." >&2
	hdiutil create -volname "SmartMeet" -srcfolder build/SmartMeet.app -ov -format UDZO "$DMG" \
		|| fail "Failed to create the .dmg."
fi
echo "✓ $DMG"

step "Git tag"
git tag -a "$VERSION" -m "SmartMeet $VERSION"
git push origin "$VERSION"

step "GitHub release"
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
{
	echo "## SmartMeet ${VERSION#v}"
	echo

	# The content accumulated in RELEASE_NOTES.md (Added/Changed/Fixed) comes
	# before the Gatekeeper warning, which stays generic from one release to
	# the next.
	if [ -f RELEASE_NOTES.md ]; then
		sed -n '/^## Unreleased/,$p' RELEASE_NOTES.md | tail -n +2
		echo
	fi

	cat <<'EOF'
⚠️ **This build isn't notarized by Apple** (requires a paid developer
account). macOS will show a warning the first time you open it — that's
expected for software distributed outside the App Store, not a sign of
danger.

To open it despite the warning:
1. Unpack the `.dmg` and drag `SmartMeet.app` into `/Applications`.
2. **Right-click the app → Open**, then confirm in the popup (once).

If macOS refuses even that option ("App is damaged" on some versions),
lift the quarantine flag from the command line:
```sh
xattr -cr /Applications/SmartMeet.app
```
EOF
} >"$NOTES"

GH_ARGS=(release create "$VERSION" "$DMG" --title "SmartMeet ${VERSION#v}" --notes-file "$NOTES")
[ "$DRAFT" = true ] && GH_ARGS+=(--draft)
gh "${GH_ARGS[@]}"

printf '\n\033[32m✓ Release %s published\033[0m\n' "$VERSION"

# --- Resetting the release notes ----------------------------------------------
#
# RELEASE_NOTES.md accumulates between two releases (see AGENTS.md); once this
# one is published, its content is reused above and the file starts over
# empty for the next one. Nothing happens in draft mode: a --draft release
# isn't actually published yet.
if [ "$DRAFT" = false ] && [ -f RELEASE_NOTES.md ]; then
	step "Resetting RELEASE_NOTES.md"
	cat >RELEASE_NOTES.md <<'EOF'
<!--
Release notes being accumulated — do NOT clear or restart this between two
releases: every shipped feature is added here as it lands (see AGENTS.md).

`Scripts/release.sh` reuses this file's content to compose the GitHub release
notes, then resets it to this template once the release is published.
-->

## Unreleased

### Added

### Changed

### Fixed
EOF
	git add RELEASE_NOTES.md
	git commit -m "Reset RELEASE_NOTES.md after release ${VERSION}"
	git push
	echo "✓ RELEASE_NOTES.md reset and pushed"
fi
