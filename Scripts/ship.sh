#!/usr/bin/env bash
# Checks, commits, and pushes.
#
#     Scripts/ship.sh "Commit message"
#     Scripts/ship.sh --no-push "Message"
#     Scripts/ship.sh --amend
#
# Nothing is committed unless the build, the tests, and the secret scan all
# pass: a commit that doesn't build costs more to undo than to avoid.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PUSH=true
AMEND=false
MESSAGE=""

while [ $# -gt 0 ]; do
	case "$1" in
	--no-push) PUSH=false ;;
	--amend) AMEND=true ;;
	-h | --help)
		sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*)
		echo "Unknown option: $1" >&2
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

# --- Is there anything to do? -------------------------------------------------

if [ "$AMEND" = false ] && [ -z "$(git status --porcelain)" ]; then
	step "Nothing to commit"
	if [ "$PUSH" = true ] && [ -n "$(git log '@{u}..' --oneline 2>/dev/null)" ]; then
		echo "Local commits are still waiting to be pushed."
	else
		echo "Working tree is clean and up to date."
		exit 0
	fi
fi

if [ "$AMEND" = false ] && [ -z "$MESSAGE" ] && [ -n "$(git status --porcelain)" ]; then
	fail "Missing commit message. Usage: Scripts/ship.sh \"Message\""
fi

# --- Checks --------------------------------------------------------------------

step "Build"
# `--warnings-as-errors` doesn't exist in SwiftPM: we count warnings ourselves.
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build 2>&1 | tee "$BUILD_LOG"; then
	fail "Build failed."
fi
WARNINGS=$(grep -c "warning:" "$BUILD_LOG" || true)
if [ "$WARNINGS" -gt 0 ]; then
	grep "warning:" "$BUILD_LOG" | head -10
	fail "$WARNINGS compiler warning(s). Fix them before committing."
fi
echo "✓ build with no warnings"

step "Tests"
TEST_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG" "$TEST_LOG"' EXIT
if ! swift test 2>&1 | tee "$TEST_LOG" | grep -E "✔|✘|Test run"; then
	fail "Tests failed."
fi
grep -q "✘" "$TEST_LOG" && fail "At least one test failed."
echo "✓ $(grep -o 'Test run with [0-9]* tests' "$TEST_LOG" | head -1)"

step "Signed bundle"
./Scripts/bundle-app.sh >/dev/null || fail "Bundle assembly failed."
codesign --verify --strict build/SmartMeet.app || fail "Invalid signature."
echo "✓ build/SmartMeet.app"

# --- Secret scan -----------------------------------------------------------
#
# This repo handles Atlassian tokens and account identifiers: an automated
# check beats a careful read-through on a late-night rush commit.

step "Secret scan"
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
	fail "Potential secret detected in the changes. Nothing was committed."
fi
echo "✓ no secret detected"

# --- Commit ----------------------------------------------------------------

step "Changes"
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

# --- Push --------------------------------------------------------------------

if [ "$PUSH" = false ]; then
	echo
	echo "Push skipped (--no-push)."
	exit 0
fi

step "Push"
BRANCH=$(git branch --show-current)
if [ "$AMEND" = true ] && git log "@{u}.." --oneline >/dev/null 2>&1 &&
	[ -z "$(git log '@{u}..' --oneline)" ]; then
	# Amending an already-pushed commit requires a force-push: not done
	# implicitly, since the branch may be shared.
	fail "The amended commit is already published. Push explicitly if you know what you're doing."
fi

if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
	git push
else
	git push -u origin "$BRANCH"
fi

printf '\n\033[32m✓ %s pushed to %s\033[0m\n' "$(git log --oneline -1)" "$BRANCH"
