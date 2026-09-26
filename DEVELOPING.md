# Developing iDVolume

## Trying an update, then publishing it

```sh
./apply-update.sh ~/Downloads/iDVolume-<version>-src.zip   # test branch, build, open test app
./publish.sh                                               # happy: merge, release, push
./discard-update.sh                                        # not happy: back to how it was
```

- `apply-update.sh` never touches `main` or your installed app. It lists every file the update
  changed, so anything unexpected stands out before you publish.
- `publish.sh` refuses to run if the version was already released or has no `## <version>`
  section in `CHANGELOG.md`, and stops at the first error.
- Each release needs a new version number (`Info.plist` → `CFBundleShortVersionString`): the
  app's updater only offers versions newer than its own.

## Making changes yourself

Edit on a branch (`git switch -c my-change`), build with `./build.sh`, and when you're happy:
bump the version, add a changelog section, commit, then `./publish.sh` from `main` after merging.
