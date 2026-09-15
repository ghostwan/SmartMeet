#!/usr/bin/env bash
# Resolves which codesigning identity to sign SmartMeet.app (or a spike) with,
# and exports it in IDENTITY. Meant to be sourced, not executed directly.
#
# TCC (microphone, system audio capture) ties permissions to the bundle's exact
# signature: switching identity between builds makes macOS ask for permission
# again, or silently revokes what was already granted. The choice therefore
# needs to stay stable across builds — hence the cache file below, so the user
# is asked once per machine, not on every `bundle-app.sh` run (itself called by
# `ship.sh` on every commit).
#
# Call `resolve_sign_identity` after `cd`-ing to the repo root: the cache file
# path is relative to the current directory.

resolve_sign_identity() {
	if [ -n "${SMARTMEET_SIGN_IDENTITY:-}" ]; then
		IDENTITY="$SMARTMEET_SIGN_IDENTITY"
		return
	fi

	local cache_file="build/.sign-identity"
	local available
	available="$(security find-identity -v -p codesigning | awk -F'"' '/[0-9]+\)/ {print $2}')"

	if [ -z "$available" ]; then
		echo "No codesigning identity found in the keychain. Import a .p12 first (see AGENTS.md), or set SMARTMEET_SIGN_IDENTITY." >&2
		exit 1
	fi

	# A previously cached choice is reused as long as it's still present in the
	# keychain — this is what keeps repeated `bundle-app.sh` runs from prompting
	# every time.
	if [ -f "$cache_file" ]; then
		local cached
		cached="$(cat "$cache_file")"
		if [ -n "$cached" ] && grep -qxF "$cached" <<<"$available"; then
			IDENTITY="$cached"
			return
		fi
	fi

	local count
	count="$(grep -c . <<<"$available")"

	if [ "$count" -eq 1 ]; then
		IDENTITY="$available"
	else
		if [ ! -t 0 ]; then
			echo "Several codesigning identities are available and there's no terminal to choose from." >&2
			echo "Set SMARTMEET_SIGN_IDENTITY, or run this script interactively once to pick and cache one." >&2
			exit 1
		fi
		echo "Several codesigning identities are available:" >&2
		local i=1
		while IFS= read -r line; do
			echo "  $i) $line" >&2
			i=$((i + 1))
		done <<<"$available"
		local choice
		read -r -p "Identity to use [1-$((i - 1))]: " choice
		IDENTITY="$(sed -n "${choice}p" <<<"$available")"
		if [ -z "$IDENTITY" ]; then
			echo "Invalid choice." >&2
			exit 1
		fi
	fi

	mkdir -p "$(dirname "$cache_file")"
	echo "$IDENTITY" >"$cache_file"
}
