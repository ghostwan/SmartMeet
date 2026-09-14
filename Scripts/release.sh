#!/usr/bin/env bash
# Construit SmartMeet.app, l'empaquette en .dmg et publie une release GitHub.
#
#     Scripts/release.sh v0.1.0
#     Scripts/release.sh v0.1.0 --draft
#
# Distribution hors App Store : sans certificat Developer ID (payant) ni
# notarization, le .dmg n'est pas reconnu par Gatekeeper. La release inclut donc
# une note expliquant comment contourner l'avertissement (clic droit → Ouvrir, ou
# `xattr -cr`). Voir TODO.md pour passer à une distribution notariée plus tard.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
DRAFT=false
[ "${2:-}" = "--draft" ] && DRAFT=true

if [ -z "$VERSION" ]; then
	echo "Usage : Scripts/release.sh vX.Y.Z [--draft]" >&2
	exit 1
fi
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
	echo "Le tag doit ressembler à v0.1.0 (reçu : $VERSION)." >&2
	exit 1
fi
if git rev-parse "$VERSION" >/dev/null 2>&1; then
	echo "Le tag $VERSION existe déjà." >&2
	exit 1
fi

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() {
	printf '\033[31m✗ %s\033[0m\n' "$1" >&2
	exit 1
}

step "Bundle signé (release)"
SMARTMEET_CONFIGURATION=release ./Scripts/bundle-app.sh || fail "L'assemblage du bundle a échoué."
codesign --verify --strict build/SmartMeet.app || fail "Signature invalide."

step "Image disque"
DMG="build/SmartMeet-${VERSION#v}.dmg"
rm -f "$DMG"
swift Scripts/make-dmg-background.swift >/dev/null || fail "Échec de la génération du fond du .dmg."
if command -v create-dmg >/dev/null 2>&1; then
	# create-dmg renvoie un code non nul même en cas de succès (Finder tarde parfois
	# à écrire les métadonnées de fenêtre) : on juge du résultat par la présence du
	# fichier, pas par le code de sortie.
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
	[ -f "$DMG" ] || fail "Échec de la création du .dmg (create-dmg)."
else
	echo "create-dmg introuvable (brew install create-dmg) — .dmg basique sans glisser-déposer visuel." >&2
	hdiutil create -volname "SmartMeet" -srcfolder build/SmartMeet.app -ov -format UDZO "$DMG" \
		|| fail "Échec de la création du .dmg."
fi
echo "✓ $DMG"

step "Tag git"
git tag -a "$VERSION" -m "SmartMeet $VERSION"
git push origin "$VERSION"

step "Release GitHub"
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
{
	echo "## SmartMeet ${VERSION#v}"
	echo

	# Le contenu accumulé dans RELEASE_NOTES.md (Added/Changed/Fixed) précède
	# l'avertissement Gatekeeper, générique lui, d'une release à l'autre.
	if [ -f RELEASE_NOTES.md ]; then
		sed -n '/^## Unreleased/,$p' RELEASE_NOTES.md | tail -n +2
		echo
	fi

	cat <<'EOF'
⚠️ **Cette build n'est pas notariée par Apple** (nécessite un compte développeur
payant). macOS affichera un avertissement à la première ouverture — c'est normal
pour un logiciel distribué hors App Store, pas un signe de danger.

Pour l'ouvrir malgré l'avertissement :
1. Décompresse le `.dmg` et glisse `SmartMeet.app` dans `/Applications`.
2. **Clic droit sur l'app → Ouvrir**, puis confirme dans la popup (une seule fois).

Si macOS refuse même cette option (« App is damaged » sur certaines versions),
lève la quarantaine en ligne de commande :
```sh
xattr -cr /Applications/SmartMeet.app
```
EOF
} >"$NOTES"

GH_ARGS=(release create "$VERSION" "$DMG" --title "SmartMeet ${VERSION#v}" --notes-file "$NOTES")
[ "$DRAFT" = true ] && GH_ARGS+=(--draft)
gh "${GH_ARGS[@]}"

printf '\n\033[32m✓ Release %s publiée\033[0m\n' "$VERSION"

# --- Réinitialisation des notes de release ------------------------------------
#
# RELEASE_NOTES.md s'accumule entre deux releases (voir AGENTS.md) ; une fois
# celle-ci publiée, son contenu est repris ci-dessus et le fichier repart vide
# pour la suivante. Rien n'est fait en mode brouillon : une release --draft n'est
# pas encore réellement publiée.
if [ "$DRAFT" = false ] && [ -f RELEASE_NOTES.md ]; then
	step "Réinitialisation de RELEASE_NOTES.md"
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
	git commit -m "Réinitialise RELEASE_NOTES.md après la release ${VERSION}"
	git push
	echo "✓ RELEASE_NOTES.md réinitialisé et poussé"
fi
