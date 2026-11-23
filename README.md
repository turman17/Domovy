# Domovy

Native macOS app and `domo` CLI that clean up after AI coding agents. See `PLAN.md` for the product plan and `CLAUDE.md` for the safety rules.

## Build and test

Requires Swift 6 / Xcode 16 or newer, macOS 14+.

```sh
swift build
swift test
```

## Running the app

Open `Domovy.xcodeproj` (not the package) and press ⌘R. The `Domovy` scheme sets `DOMOVY_ROOT` to `.devhome/`, a fake home copied from the fixtures, so Debug runs never touch your real `~`. New Swift files in `App/` are picked up without editing the project.

From the terminal (shares DerivedData with Xcode):

```sh
make run            # build Debug and launch against .devhome
make reset-devhome  # restore .devhome after trying deletes
make test           # swift test
```

To run against your real home, untick `DOMOVY_ROOT` in the scheme's Run > Environment Variables.

## Running the CLI

`domo` scans a home directory. The default is your own home. Every command accepts `--root <home>` to point it elsewhere; during development always run mutating commands against a copy of the fixture home, never against `~`:

```sh
mkdir -p /tmp/domo-home && cp -R Tests/Fixtures/claude-code/2.1 /tmp/domo-home/.claude

swift run domo ls --root /tmp/domo-home
swift run domo du --root /tmp/domo-home
swift run domo rm aaaaaaaa --root /tmp/domo-home --dry-run
swift run domo rm aaaaaaaa --root /tmp/domo-home --to quarantine
swift run domo undo --root /tmp/domo-home
```

Removed files go to the Trash (default) or to `<home>/Library/Application Support/Domovy/Quarantine`; every run writes an undo entry next to it under `Undo/`.
