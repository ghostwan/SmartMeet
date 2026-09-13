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
hdiutil create -volname "SmartMeet" -srcfolder build/SmartMeet.app -ov -format UDZO "$DMG" \
	|| fail "Échec de la création du .dmg."
echo "✓ $DMG"

step "Tag git"
git tag -a "$VERSION" -m "SmartMeet $VERSION"
git push origin "$VERSION"

step "Release GitHub"
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
cat >"$NOTES" <<EOF
## SmartMeet ${VERSION#v}

⚠️ **Cette build n'est pas notariée par Apple** (nécessite un compte développeur
payant). macOS affichera un avertissement à la première ouverture — c'est normal
pour un logiciel distribué hors App Store, pas un signe de danger.

Pour l'ouvrir malgré l'avertissement :
1. Décompresse le \`.dmg\` et glisse \`SmartMeet.app\` dans \`/Applications\`.
2. **Clic droit sur l'app → Ouvrir**, puis confirme dans la popup (une seule fois).

Si macOS refuse même cette option (« App is damaged » sur certaines versions),
lève la quarantaine en ligne de commande :
\`\`\`sh
xattr -cr /Applications/SmartMeet.app
\`\`\`
EOF

GH_ARGS=(release create "$VERSION" "$DMG" --title "SmartMeet ${VERSION#v}" --notes-file "$NOTES")
[ "$DRAFT" = true ] && GH_ARGS+=(--draft)
gh "${GH_ARGS[@]}"

printf '\n\033[32m✓ Release %s publiée\033[0m\n' "$VERSION"
