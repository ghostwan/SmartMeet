#!/usr/bin/env bash
# Vérifie, commite et pousse.
#
#     Scripts/ship.sh "Message de commit"
#     Scripts/ship.sh --no-push "Message"
#     Scripts/ship.sh --amend
#
# Rien n'est commité tant que le build, les tests et le contrôle de secrets ne
# passent pas : un commit qui ne compile pas coûte plus cher à défaire qu'à éviter.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PUSH=true
AMEND=false
SKIP_TESTS=false
MESSAGE=""

while [ $# -gt 0 ]; do
	case "$1" in
	--no-push) PUSH=false ;;
	--amend) AMEND=true ;;
	--skip-tests) SKIP_TESTS=true ;;
	-h | --help)
		sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*)
		echo "Option inconnue : $1" >&2
		exit 1
		;;
	*) MESSAGE="$1" ;;
	esac
	shift
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() {
	printf '\033[31m✗ %s\033[0m\n' "$1" >&2
	exit 1
}

# --- Y a-t-il quelque chose à faire ------------------------------------------

if [ "$AMEND" = false ] && [ -z "$(git status --porcelain)" ]; then
	step "Rien à commiter"
	if [ "$PUSH" = true ] && [ -n "$(git log '@{u}..' --oneline 2>/dev/null)" ]; then
		echo "Des commits locaux restent à pousser."
	else
		echo "L'arbre de travail est propre et à jour."
		exit 0
	fi
fi

if [ "$AMEND" = false ] && [ -z "$MESSAGE" ] && [ -n "$(git status --porcelain)" ]; then
	fail "Message de commit manquant. Usage : Scripts/ship.sh \"Message\""
fi

# --- Vérifications ------------------------------------------------------------

step "Build"
# `--warnings-as-errors` n'existe pas sur SwiftPM : on compte les warnings nous-mêmes.
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build 2>&1 | tee "$BUILD_LOG"; then
	fail "Le build a échoué."
fi
WARNINGS=$(grep -c "warning:" "$BUILD_LOG" || true)
if [ "$WARNINGS" -gt 0 ]; then
	grep "warning:" "$BUILD_LOG" | head -10
	fail "$WARNINGS warning(s) de compilation. Corrige-les avant de commiter."
fi
echo "✓ build sans warning"

if [ "$SKIP_TESTS" = false ]; then
	step "Tests"
	TEST_LOG="$(mktemp)"
	trap 'rm -f "$BUILD_LOG" "$TEST_LOG"' EXIT
	if ! swift test 2>&1 | tee "$TEST_LOG" | grep -E "✔|✘|Test run"; then
		fail "Les tests ont échoué."
	fi
	grep -q "✘" "$TEST_LOG" && fail "Au moins un test a échoué."
	echo "✓ $(grep -o 'Test run with [0-9]* tests' "$TEST_LOG" | head -1)"
fi

step "Bundle signé"
./Scripts/bundle-app.sh >/dev/null || fail "L'assemblage du bundle a échoué."
codesign --verify --strict build/SmartMeet.app || fail "Signature invalide."
echo "✓ build/SmartMeet.app"

# --- Contrôle de secrets ------------------------------------------------------
#
# Le dépôt manipule des jetons Atlassian et des identifiants de compte : un
# contrôle automatique vaut mieux qu'une relecture attentive un soir de rush.

step "Contrôle de secrets"
git add -A
STAGED=$(git diff --cached --name-only --diff-filter=ACM)
LEAKS=""
if [ -n "$STAGED" ]; then
	LEAKS=$(git diff --cached -U0 -- $STAGED |
		grep -E "^\+" |
		grep -oE "(ATATT[A-Za-z0-9_=-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})" |
		sort -u || true)
fi
if [ -n "$LEAKS" ]; then
	echo "$LEAKS" | sed 's/^/  /'
	git reset >/dev/null
	fail "Secret potentiel détecté dans les modifications. Rien n'a été commité."
fi
echo "✓ aucun secret détecté"

# --- Commit -------------------------------------------------------------------

step "Modifications"
git diff --cached --stat | tail -20

if [ "$AMEND" = true ]; then
	if [ -n "$MESSAGE" ]; then
		git commit --amend -m "$MESSAGE"
	else
		git commit --amend --no-edit
	fi
else
	git commit -m "$MESSAGE"
fi

step "Commit"
git log --oneline -1

# --- Push ---------------------------------------------------------------------

if [ "$PUSH" = false ]; then
	echo
	echo "Push ignoré (--no-push)."
	exit 0
fi

step "Push"
BRANCH=$(git branch --show-current)
if [ "$AMEND" = true ] && git log "@{u}.." --oneline >/dev/null 2>&1 &&
	[ -z "$(git log '@{u}..' --oneline)" ]; then
	# Amender un commit déjà poussé impose un push forcé : on ne le fait pas
	# implicitement, la branche peut être partagée.
	fail "Le commit amendé est déjà publié. Pousse explicitement si tu sais ce que tu fais."
fi

if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
	git push
else
	git push -u origin "$BRANCH"
fi

printf '\n\033[32m✓ %s poussé sur %s\033[0m\n' "$(git log --oneline -1)" "$BRANCH"
