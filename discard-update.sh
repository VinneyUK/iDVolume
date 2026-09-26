#!/bin/bash
# Throw away the update being tested and go back to exactly what you had.
set -euo pipefail
cd "$(dirname "$0")"

BRANCH=$(git branch --show-current)
if [[ "$BRANCH" != update/* ]]; then
  echo "Not testing an update (you're on '$BRANCH'), so there's nothing to discard."
  exit 0
fi
git reset -q --hard
git switch -q main
git branch -q -D "$BRANCH"
killall iDVolume 2>/dev/null || true
sleep 1
open /Applications/iDVolume.app 2>/dev/null || true
echo "✓ Discarded '$BRANCH'. You're back on main, and your installed app is running again."
