#!/bin/bash
# Publish the version you've tested: merge it, build the download, tag, push, create the release.
# Stops at the first problem and says why.
set -euo pipefail
cd "$(dirname "$0")"

BRANCH=$(git branch --show-current)
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "✗ You have uncommitted changes:"; git status --short
  echo "  Commit them (git add -A && git commit -m \"…\") and run ./publish.sh again."
  exit 1
fi
if [[ "$BRANCH" == update/* ]]; then
  git switch -q main
  git merge -q --no-edit "$BRANCH"
  git branch -q -d "$BRANCH"
  echo "→ Merged $BRANCH into main"
elif [ "$BRANCH" != "main" ]; then
  echo "✗ Switch to main (or an update/… branch) first — you're on '$BRANCH'."
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
if ! grep -q "^## $VERSION\$" CHANGELOG.md; then
  echo "✗ CHANGELOG.md has no '## $VERSION' section. Add one describing this release, commit, and try again."
  exit 1
fi

./release.sh    # refuses if v$VERSION was already released

NOTES=$(mktemp)
awk "/^## $VERSION\$/{f=1;next} /^## /{f=0} f" CHANGELOG.md > "$NOTES"
echo "→ Release notes:"; cat "$NOTES"

git tag "v$VERSION"
git push -q origin main
git push -q origin "v$VERSION"
gh release create "v$VERSION" "dist/iDVolume-$VERSION.zip" "dist/iDVolume-$VERSION.zip.sha256" \
  --title "iDVolume $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"

echo
echo "✓ Published $VERSION."
echo "  Update your own copy: Settings → Updates → Check Now → Install & Restart"
