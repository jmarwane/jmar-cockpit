# Cue

Menu-bar utility for commands, scripts, services, links and reminders. Spec: `docs/SPEC.md`.
Decisions the spec doesn't cover go in `docs/DECISIONS.md`, one line each, with the reason.

## Build and test

If `xcode-select -p` shows CommandLineTools: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
xcodegen generate                                   # regenerate Cue.xcodeproj from project.yml
xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Debug \
  -derivedDataPath build build                      # build the app
swift test --package-path CueCore                   # CueCore unit tests
xcodebuild -project Cue.xcodeproj -scheme Cue \
  -derivedDataPath build test                       # full test run
open build/Build/Products/Debug/Cue.app             # launch
```

## Working rules

- One milestone at a time (spec §15). At the end of each: build with xcodebuild,
  run the tests, commit, give a 3–6 step manual checklist, then stop for review.
- Never run commands from items saved in Cue. Tests use temp directories and
  fixture scripts written for the tests.
- Never write into `/opt/homebrew`, `/usr/local` or the home folder, except
  `~/Library/Application Support/Cue` and this repo.
- No dependencies beyond `KeyboardShortcuts` (Sindre Sorhus) without asking.
- Don't build anything from spec §17 (Later) or §18 (Out of scope). If a step
  seems to need one, say so and propose the smallest alternative.
- Ambiguity or contradiction: pick the reading that keeps status honest and the
  UI simpler, note it in `docs/DECISIONS.md`, continue.
- Status is observed, never assumed. Never kill a process by name. Never splice
  input values into command text.

## Layout

- `project.yml`: XcodeGen definition (app target `Cue`, macOS 26, LSUIElement).
- `CueCore/`: local Swift package, no UI (models, store, runner, checks, parsing).
- `Cue/`: the app (AppKit status item + NSPanel hosting SwiftUI).
