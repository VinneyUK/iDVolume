#!/bin/bash
# Try an update from a source zip on a separate test branch. Nothing is published.
#   ./apply-update.sh ~/Downloads/iDVolume-<version>-src.zip
# Then:  ./publish.sh  (happy)   or   ./discard-update.sh  (not happy)
set -euo pipefail
cd "$(dirname "$0")"

ZIP="${1:-}"
if [ ! -f "$ZIP" ]; then
  echo "usage: ./apply-update.sh ~/Downloads/iDVolume-<version>-src.zip"
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "✗ You have uncommitted changes. Commit them, or run ./discard-update.sh, first."
  git status --short
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
SRC="$TMP/iDVolume"
if [ ! -d "$SRC/Sources" ]; then
  echo "✗ That zip doesn't contain the iDVolume project."
  exit 1
fi

plist() { /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$1"; }
CUR=$(plist Info.plist)
NEW=$(plist "$SRC/Info.plist")
BRANCH="update/$NEW"

# Always start the test branch from main.
if [ "$(git branch --show-current)" != "main" ]; then git switch -q main; fi
git switch -q -C "$BRANCH"

# Copy the update in. --delete removes files the update no longer has; git can undo anything.
rsync -a --delete --exclude .git --exclude build --exclude dist --exclude .DS_Store "$SRC/" ./
git add -A
if git diff --cached --quiet; then
  echo "Nothing changed — this zip is the same as your current code."
  git switch -q main && git branch -q -D "$BRANCH"
  exit 0
fi
git commit -q -m "Update to $NEW"

echo
echo "Update $CUR → $NEW, on test branch '$BRANCH'. Files changed:"
git show --stat --format="" HEAD
[ "$CUR" = "$NEW" ] && echo "⚠ The version number didn't change ($NEW) — you'll need to bump it before publishing."

echo
echo "→ Building…"
if ! ./build.sh > /tmp/idvolume-build.log 2>&1; then
  grep -E "error:" /tmp/idvolume-build.log | head -30 || tail -30 /tmp/idvolume-build.log
  echo "✗ Build failed (full log: /tmp/idvolume-build.log). Send Claude the errors above, or ./discard-update.sh"
  exit 1
fi
killall iDVolume 2>/dev/null || true
sleep 1
open build/iDVolume.app
echo "✓ Test build of $NEW is running (your installed app is untouched)."
echo "  Happy?      ./publish.sh"
echo "  Not happy?  ./discard-update.sh"
