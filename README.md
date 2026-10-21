# jmar-cockpit

Home of **Cue**, a personal macOS menu-bar app for the things I launch often: shell commands, scripts, local servers, Docker containers, links and reminders. One click runs, starts, stops or opens each one, and every row says honestly what is happening.

The goal: start something, go back to work, and know whether it finished, is still running or needs attention, without opening Terminal to check.

Cue is local only: no accounts, no cloud, not sandboxed, not for the App Store. It ships with no example items.

## What it does

- **Services** keep running until stopped, like a dev server or a container. Cue shows them as On only when a check says so: the process it started is alive, a port responds, or a status command exits 0. When it can't tell, it says Unknown.
- **Tasks** run and finish. Their row shows Running, then Done or Failed, along with the time and the result line the script printed.
- **Links** open anything macOS can open: a URL, a localhost address, a folder, a file or an app.
- **Reminders** have a text and a due time, typed in plain words like `stretch in 20m` or `call the bank at 18:30`.

Open the panel with ⌃⌥Space or the menu-bar icon. Type to search, or paste a command, URL or reminder and press ↵ to add it. ⌘↵ runs a command once without saving it. ⌘K shows the actions for the selected row, and ⌘, opens Settings.

The editor window has a **Test Run** button that tries an item's setup before you rely on it. Secret environment variables are stored in the Keychain, never in the item file or the logs.

## Requirements

- macOS 26 or later
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

The only dependency is [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), fetched by Swift Package Manager.

## Build and run

```sh
xcodegen generate          # creates Cue.xcodeproj from project.yml
xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Release \
  -derivedDataPath build build
ditto build/Build/Products/Release/Cue.app /Applications/Cue.app
open /Applications/Cue.app
```

For development, build with `-configuration Debug` and open `build/Build/Products/Debug/Cue.app`.

If `xcode-select -p` points at the Command Line Tools, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` or set `DEVELOPER_DIR` to that path.

The build is signed ad hoc, so macOS treats every rebuild as a new app. After you replace it, macOS asks once for each secret whether Cue may read it from the Keychain.

## Tests

```sh
swift test --package-path CueCore                                    # CueCore only
xcodebuild -project Cue.xcodeproj -scheme Cue -derivedDataPath build test  # everything
```

The tests run fixture scripts in temporary directories. They never touch your items, your Keychain or your data folder.

## Where Cue keeps things

| What | Where |
|---|---|
| Items and reminders | `~/Library/Application Support/Cue/items.json`, with a backup in `items.json.bak` |
| Processes Cue started, for picking them up after a crash | `~/Library/Application Support/Cue/running.json` |
| The last 20 runs of each item | `~/Library/Application Support/Cue/runs/<item id>/` |
| Settings | macOS preferences for `com.jmarwane.cue` |
| Secrets | the login Keychain, service `Cue` |

## Repository layout

- `Cue/`: the app. An AppKit status item and a borderless panel that hosts SwiftUI views, plus the editor, log and Settings windows.
- `CueCore/`: a Swift package with no UI. It holds the item model, storage, process spawning, checks, the status state machine, quick-add parsing and reminders. Most of the tests live here.
- `project.yml`: the XcodeGen project definition.

## Docs

- [`docs/SPEC.md`](docs/SPEC.md): the full spec Cue was built from.
- [`docs/WRITING-TOOLS.md`](docs/WRITING-TOOLS.md): how to write commands and scripts that work well in Cue. It covers inputs, the `::cue result` and `::cue reason` lines, and the exit codes status commands use.
- [`docs/DECISIONS.md`](docs/DECISIONS.md): every choice the spec didn't settle, one line each, with the reason.
