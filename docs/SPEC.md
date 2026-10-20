# Build Cue: a menu-bar app for commands, scripts, links and reminders

You are building **Cue**, a personal macOS menu-bar utility, together with me. This document is the spec. Read all of it before writing any code.

---

## 0. How we work

**Before any code:**

1. In this repo (run `git init` if needed), save this document as `docs/SPEC.md`. Create a short `CLAUDE.md` (40 lines or fewer) containing the build and test commands, the working rules below, and a pointer to the spec.
2. Check the toolchain: `sw_vers`, `xcodebuild -version`, `swift --version`, and whether `xcodegen` is installed. If XcodeGen is missing, ask me before installing it with Homebrew.
3. Propose the file layout and your plan for Milestone 0 in 30 lines or fewer. Wait for my OK.

**Throughout:**

- Work one milestone at a time (section 15). At the end of each one:
  - build with `xcodebuild`;
  - run the tests;
  - commit;
  - give me a checklist of 3–6 steps to try the milestone by hand.

  Then stop and wait for my review.
- Record every decision this spec doesn't cover in `docs/DECISIONS.md`, one line each, with the reason.
- Never run commands from items I save in Cue. Tests use temporary directories and fixture scripts you write yourself.
- Never write into `/opt/homebrew`, `/usr/local`, or my home folder. The only exceptions are `~/Library/Application Support/Cue` and this repo.
- Add no dependencies beyond the one listed in section 13 without asking.
- Don't build anything from "Later" (section 17) or "Out of scope" (section 18). If a step seems to need one of them, say so and propose the smallest alternative.
- If the spec is ambiguous or contradicts itself, choose the reading that keeps status honest and the UI simpler. Note it in `DECISIONS.md` and continue.

---

## 1. What Cue is

Cue lives in the menu bar. It holds a short list of things I launch often: shell commands, scripts, local servers, Docker containers, links and reminders. One click runs, starts, stops or opens each item, and every row says honestly what is happening.

**The promise:** start something, go back to work, and know whether it finished, is still running or needs attention, without opening Terminal to check.

It is a personal tool: local only, no accounts, no cloud, no AI at runtime, not sandboxed, not for the App Store. **It ships with no example items.** What goes in it is up to me.

Three principles drive every decision:

1. **Status is observed, never assumed.** A service is On because a check says so, not because Cue launched it a minute ago.
2. **One click does what the row says.** The row's glyph and the footer both show the action before you click.
3. **Unknown is a real answer.** When Cue can't tell, it says so and offers a check.

---

## 2. Item model

Each item is one of three kinds. Reminders are separate.

| Kind | What it is | One click |
|---|---|---|
| **Service** | Keeps running until stopped (a dev server, a container) | Start / Stop |
| **Task** | Runs and finishes (a script, a report) | Run |
| **Link** | Anything macOS can open: a URL, a localhost address, a folder, a file, an app | Open |
| **Reminder** | Text and a due time. Created from the panel; not an item kind. | Change / Dismiss |

### Stored fields

- **All items:** `id` (UUID), `kind`, `name`, `icon` (SF Symbol name), `tint` (sky, rose, amber, sage, plum, sand), `order`.
- **Task and Service:**
  - `command` (multi-line text), `workingDirectory` (default `~`), `shell` (zsh by default; bash or sh)
  - `environment`: a list of `{key, value, isSecret}`. Secret values live in the Keychain, never in the JSON.
  - `inputs`: a list of `{name, defaultValue}`; `lastInputs`
  - `timeLimit` (none, 30 s, 2 min, 10 min or custom), `confirmBeforeRunning` (bool), `keepOutput` (bool, default true), `testedSignature`
- **Service only:**
  - `runningWhen`: `process` | `port(String)` | `statusCommand(String)`
  - `stopBy`: `process` | `command(String)`
  - `address` (optional, e.g. `localhost:$PORT`): shown in the subtitle and offered as "Open"
- **Link:** `target` (a URL or a file path).
- **Reminder:** `id`, `text`, `due`, `state` (pending or fired), `firedAt`, `notificationID`.

### Inputs

- Each input reaches the command as an **environment variable** with the same name, and the command refers to it as `"$PORT"`.
- **Never splice input values into the command text.**
- The `port` and `address` fields may contain `$NAME`; Cue substitutes those itself. A port must resolve to a number from 1 to 65535.

### Tested signature

A hash of:

- kind, command, folder and shell
- environment keys (not secret values)
- inputs
- running-when and stop-by

When the hash differs from `testedSignature`, the item is **Not yet tested** (section 7).

---

## 3. Status

### The three checks

A service's status comes only from its check:

- **Its process is alive.** The process group Cue started still exists. This only sees processes Cue started, and the editor says so.
  - If the start command exits within 3 s with this check selected, mark it Failed with the reason `Exited right away. If it starts something in the background, use a port or status check.`
- **A port responds.** A TCP connection to 127.0.0.1 and ::1 on the port succeeds within 1 s.
- **A status command.** Run with a 5 s timeout and read the result by exit code:
  - exit 0 = **On**
  - exit 1 = **Off**
  - any other exit code, a timeout, or a failure to launch = **Unknown**. Show the first line of stderr as the reason.

### States

- **Service:** Off, Starting, On, Stopping, Failed, Unknown, plus a temporary Checking flag.
- **Task:** Ready (never run), Running, Done, Failed, Cancelled.
- **Not yet tested:** applies to any idle task or service.

Keep these three statements separate in both code and UI:

- "The command exited 0": a start command or task finished successfully.
- "The service is On": its check passed.
- "Done": for a task, this only means exit 0. It says nothing about whether the output is correct.

### Transitions

- **Start:**
  1. Run the check first. If the service is already On, don't launch; show `On · started outside Cue`.
  2. Otherwise launch → **Starting** → poll the check every 500 ms for up to 30 s.
  3. When the check passes → **On**.
  4. On failure → **Failed**, with `Didn't come up in 30 s` or `Exited with code N`.

  A start command that exits 0 before the check passes (e.g. `docker start`) is normal for port and status-command checks; keep polling.
- **Stop:**
  1. **Stopping** → apply the stop method → run the check again.
  2. Go to **Off** only if the check now fails.
  3. If it still passes after 10 s → **Failed**: `Still answering on port 4000`, with a Force Stop action.
- **Unexpected exit:** if a service process Cue owns exits unexpectedly → **Failed**: `Exited unexpectedly · exit N`, plus one notification.
- **Unknown:** click → **Checking** → result.

### Ownership

- **Cue owns** the processes it starts.
- **Another manager owns** services stopped by a stop command (Docker, `brew services`…). Cue just asks it.
- **Observed, not owned:** a service that is On but wasn't started by Cue. Stopping it requires one of these:
  - its stop command, if it has one;
  - for a port service without a stop command: `Stop process on port 4000 (node, pid 4312)…`, found with `/usr/sbin/lsof -nP -iTCP:<port> -sTCP:LISTEN`, always behind a confirmation.

  **Never kill a process by name.**

---

## 4. Menu-bar icon

A monochrome template image with three states:

- **Nothing On:** two hollow dots beside two lines.
- **Something On** (a service, or a task running): the top dot filled.
- **Needs attention** (anything Failed or Unknown, or a library check-up problem): an exclamation mark replaces the bottom dot.

Clicking the icon toggles the panel. A global hotkey toggles it too (default ⌃⌥Space, changeable in Settings). The icon also accepts drops (section 6).

---

## 5. The panel

### Window behavior

- An `NSPanel` below the status item, using `nonactivatingPanel`, so the frontmost app (e.g. my DAW) stays active. It still becomes key, so typing goes straight into the search field.
- **Closes on:**
  - Esc (after clearing; see Keyboard)
  - a click outside the panel
  - opening a link or the editor
  - the hotkey
- **Stays open** after start, stop, run or check, so I can watch the transition.
- **When it opens,** every service is checked again. Glyphs whose last check is more than 30 s old are drawn at 40% opacity until the new result arrives.

### Layout (top to bottom)

1. **Search field**, 48 pt tall, placeholder `Search or paste…`, with a `+` button at the trailing edge.
2. **Rows** in my order, with no header. Below them:
   - an **Upcoming** group, shown only while reminders exist;
   - a **Recent** group, for commands run once without saving (section 6).
3. **Footer**, 40 pt tall:
   - left: a toast area (messages stay 2.8 s);
   - right: the selected row's primary action with `↵`, a separator, and `Actions ⌘K`.
4. At most 9 rows are visible; beyond that the list scrolls.

**Rows never move while the panel is open.** New items are added at the end. Filtering hides rows but never reorders them.

### Row anatomy

Each row is 48 pt tall and contains, left to right:

- a tinted icon tile
- the title (the name) above a subtitle (the state)
- a 30 × 30 pt accessory that shows the state glyph at rest and the action glyph when the row is selected or hovered

**The whole row is one button:** clicking anywhere on it does the footer action. Hovering and the arrow keys only select.

### What one click does

| Row | Glyph at rest | Subtitle example | Click |
|---|---|---|---|
| Service, Off | grey ring | `Not running · stopped 3m ago` | Start (opens the inputs form if it has inputs) |
| Service, Starting | amber spinning arc | `Starting…` | ignored |
| Service, On | green dot | `Running · 4m · localhost:4000` | Stop |
| Service, Stopping | amber reverse arc around a square | `Stopping…` | ignored |
| Service, started outside Cue | green dot | `On · started outside Cue` | Stop via its stop command; without one, an inline confirmation `Stop process on port 4000 (node, pid 4312)?` |
| Failed (any kind) | red circle with `!` | `Failed · exit 1 · Error: listen EADDRINUSE…` or `Failed · <reason>` | Show error details |
| Unknown | grey dashed ring with a dot | `Status unknown · Docker isn't responding` | Check status |
| Checking | grey spinning arc | `Checking status…` | ignored |
| Task: Ready, Done or Cancelled | none | `Ready` · `Done · saved streams.csv · 2m ago` · `Cancelled · 1m ago` | Run (opens the inputs form if it has inputs) |
| Task, Running | amber spinning arc | `Running · 42s` | Show run details: elapsed time, last output line and a **Cancel** button. **A click never cancels by itself.** |
| Not yet tested (when idle) | none | `Not yet tested` | Open the editor at Test Run |
| Link | ↗ | `localhost:4000/admin` | Open it; the panel closes |
| New Reminder (built-in row, first in the list) | › | `Write a note, pick a time` or `2 upcoming · next 23:58` | Open the inline reminder form |
| Reminder, pending | bell | `in 12 min · 23:58` | Open the inline form to change it |
| Reminder, fired | check | `Fired at 23:58` or `Was due 14:00` | Dismiss |
| Add row | + | depends on the type | See section 6 |

**Extra rules:**

- **Confirm before running:** a click on an item with `confirmBeforeRunning` opens an inline confirmation showing the final command and the input values. ↵ runs it.
- **Needs Terminal:** commands containing `sudo` are marked this way, and a click offers Run in Terminal instead.
- **Inline expansions** (inputs form, reminder form, error details, run details, confirmation) open under their row and push down only the rows below it. Esc closes them.

### Error details

Shown under the row:

- `Exit 1 · 2m ago · first error line`
- the first error line in monospace (at most 2 lines)
- `Reported by the script: <reason>`, if the script sent one
- buttons: Copy · View Log · Retry (↵)

### ⌘K actions

1. The primary action first.
2. Then whichever of these apply: Restart, Open <address>, View Log, Copy Error Details, Run in Terminal, Copy Command, Copy Link, Stop process on port…, Force Stop, Cancel Reminder.
3. A separator, then Edit… ⌘E.

### Keyboard

| Key | Action |
|---|---|
| ↑ ↓ | Select a row |
| ↵ | Primary action |
| ⌘K | Actions menu |
| ⌘E | Edit the selected item |
| Esc | Close an expansion, then clear the search, then close the panel |
| typing | Filter the list |
| Tab (on the add row) | Switch the add row's type |
| ⌘↵ (on a command add row) | Run it once without saving |
| ⌘, | Settings |

### Search and empty state

- **Search** matches item names and command text (case-insensitive substring). Reminders match on their text.
- **Empty state:** `Paste a command, drop a script, add a link, or type "stretch in 20m".`

---

## 6. Quick add

**Three entry points:**

- typing or pasting into the search field when nothing matches
- the `+` button, which shows the add row even when something matches
- dropping something on the panel or on the menu-bar icon

### Classification

Check these rules in order; the first match wins.

1. `http(s)://…`, `localhost[:port][/path]`, or a bare domain → **Link**.
2. Shell syntax (`|`, `&&`, `;`, `>`, `$`, backticks, or a flag such as ` -x` or ` --flag`), or text starting with `./`, `~/` or `/` → **Command**.
3. Text ending in a time phrase (`in 20m`, `in 2 hours`, `at 18:30`, `at 6pm`, `tomorrow`, `tomorrow at 9`) → **Reminder** at that time.
4. The first word resolves to an executable on the captured PATH (section 8), or is a shell builtin → **Command**. For example, `splash serve` must classify as a command when `splash` is installed.
5. Anything else → **Reminder** without a time.

The add row shows its guess as a small type label (`Link`, `Command` or `Reminder`), and Tab cycles through the three. **The guess never acts on its own.**

### The add row, by type

- **Link**
  - Title `Add link`, subtitle the address.
  - ↵ saves it, named after the page path or the host. The panel stays open and shows the toast `Link added`.
- **Command**
  - Title `Add command`, subtitle the command in monospace.
  - **↵ saves it and opens the editor**, with Test Run focused and the kind guessed: Service if the command contains `dev`, `serve`, `server`, `watch` or `up`; otherwise Task.
  - **⌘↵ runs it once without saving.** It appears in the Recent group showing its state, and its ⌘K menu offers Save…. Recent rows disappear when dismissed or when Cue quits.
- **Reminder with a time**
  - Title `Remind me at 23:58: "Stretch"`, subtitle the countdown.
  - ↵ sets it.
- **Reminder without a time**
  - Title `Remind me: "Water the plants"`, subtitle `Pick a time…`.
  - ↵ opens the inline reminder form with the text filled in.

Strip a leading `$ ` or `% ` from pasted commands. Multi-line pastes are kept whole, and the editor shows them in full.

### Drops

- **An executable script** → a Command add row with its absolute path, quoted.
- **A script that isn't executable:**
  - with a shebang line: the add row offers `Make executable` (`chmod +x`);
  - without one: prefix the interpreter matching the extension (`.sh` → `sh`, `.py` → `python3`) and say so.
- **A folder, an app or any other file** → Link.
- **A dragged URL or text** → classified as above.

While something is dragged over the panel or the icon, highlight it with an accent outline.

---

## 7. Editor window

A normal window of about 720 × 600 pt. It opens from ⌘E, from the Actions menu, or after adding a command, and comes to the front when opened.

- **Sidebar:**
  - every item except reminders, each with its tile and name
  - a dot marking unsaved changes; a `Not tested` note
  - drag to reorder
  - + and − buttons at the bottom; − asks for confirmation
- **Header:**
  - a large tile and the name
  - a caption for the kind:
    - `Service · stays running until stopped`
    - `Task · runs once and reports a result`
    - `Link · opens an address`
  - pills: `Unsaved changes`, `Not yet tested`, `Test passed`
- **Command** (the first section):
  - **Type:** segmented control, Service · Task · Link
  - **Run:** monospaced, multi-line
  - **Folder:** text field plus Choose…
  - **Services also get:**
    - **Running when:** Its process is alive · A port responds · A status command. Each choice shows its own field and a one-line hint. The process option's hint says it only sees processes Cue started.
    - **Stop by:** Ending the process Cue started · Running a stop command
    - **Address** (optional)
  - **Links** show only their target.
- **Inputs:**
  - rows of NAME plus default value, and an `Add Input` button
  - hint: `The menu asks for these before each run. Use them as "$NAME".`
- **Appearance:**
  - name, icon (a picker of about 12 SF Symbols), color (the 6 tints)
  - filled in automatically from the command
- **Advanced** (collapsed by default):
  - **Environment:** KEY = value rows, each with a Secret toggle
  - **Shell; Time limit**
  - **Ask before running:** switched on automatically when you save a command matching `rm -r`, `sudo`, `--force`, `git push` or `git reset --hard`
  - **Keep output**
- **Footer:** Test Run · status note · Revert · Save (⌘S)

### Test Run

It really runs the draft: it's my command and I clicked the button. The output appears inline:

1. the command with its inputs filled in
2. `Program /opt/homebrew/bin/npm` (the path actually resolved), `Folder …`, `Shell …`
3. the result:
   - **For a task:** the exit code and duration.
   - **For a service:**
     1. start it and wait up to 30 s for its check
     2. report the result, e.g. `Port 4000 answered after 2.1 s`
     3. stop it and confirm it is Off

A passing test stores the signature. Saving with a changed signature shows `Not yet tested` until a test passes.

---

## 8. Running commands

### Environment

At launch, capture the environment once from my login shell:

- Run it interactively (`$SHELL -ilc`) with stdin from /dev/null.
- Wrap the output in unique markers, so prompts or plugins printing at startup are ignored.
- Time out after 5 s, then fall back:
  1. to `-lc`
  2. then to a default PATH that includes `/opt/homebrew/bin` and `/usr/local/bin`

Settings shows the captured PATH, with a Refresh button.

### Spawning

Use `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, so every run gets its own process group:

- **Command line:** `<shell> -c <command>`, with the expanded folder as the working directory.
- **Environment:** the captured environment + `CUE=1` + the item's environment (secrets read from the Keychain) + the inputs.
- **stdin:** /dev/null, so a command waiting for input gets end-of-file instead of hanging.

### Output

- Capture stdout and stderr into one bounded buffer per run, keeping the last 256 KB.
- Track the last non-empty line, and the first error line: the first line containing `error`, `Error`, `ERR!`, `fatal` or `Traceback`, or else the last stderr line.

### Script feedback

Cue reads two kinds of line from output; if either appears more than once, the last one wins:

- `::cue result <text>` sets the result shown in Done subtitles.
- `::cue reason <text>` sets the failure reason.

Nothing else is parsed from output.

### Stopping and limits

- **Stop / Cancel:** send SIGTERM to the whole process group, wait 5 s, send SIGKILL to the group, then (for services) run the check again.
- **Time limit:** when it's exceeded, stop the group and mark the run Failed with `Timed out after 2 min`.

### Exit codes, duplicates and Terminal

- **Exit codes:**
  - 127 → `Command not found: <word>`, with the hint `Not on Cue's PATH; check Settings › Environment`
  - 126 → `Not executable`
- **Duplicates:** at most one active run per item. Services on the same port share protection: starting one while the port is taken shows `Port 4000 is already in use by <process>` instead of launching.
- **Run in Terminal:** opens Terminal with `cd <folder> && <command>` via AppleScript. This needs the Automation permission, with a usage description. It is a new run, not a hand-off of a run already going.

### Redaction

Replace known secret values with `••••` in captured output, logs, notifications and anything copied.

---

## 9. When checks run

**Services are checked again:**

- when the panel opens
- after a start or a stop
- on wake from sleep: on `NSWorkspace.didWakeNotification`, wait 2 s, showing Checking meanwhile
- every 30 s, for services that are On or Unknown
- every 5 min, for all others

**Timeouts:** 1 s for a port check, 5 s for a status command.

**Retries:** checks are retried automatically. Starts, task runs and reminders are never re-run automatically.

---

## 10. Reminders

- **Creating one:**
  - from the search field (`stretch in 20m`), or
  - from the built-in New Reminder row, which opens an inline form:
    - a text field
    - chips: `15 min` · `1 hour` · `Tomorrow 9:00`
    - the due time read from the text, shown as `Due 23:58`
    - Cancel · Set
- **Delivery:**
  - scheduled as local notifications with `UNUserNotificationCenter`, so they arrive even when Cue isn't running
  - notification actions: Snooze 10 min, Done
- **In the panel:**
  - listed in the Upcoming group, soonest first
  - pending reminders show a bell and a countdown
  - clicking one opens the form to change its text or time, with a `Keep 23:58` chip first
- **After firing:**
  - **A fired reminder stays until it is dismissed**, by Done in the notification or by a click in the panel.
  - If one came due while the Mac was asleep or Cue wasn't running, it shows `Was due 14:00`.
- **Sound:** reminders play the default notification sound. Everything else in Cue is silent.

---

## 11. Persistence, history and secrets

- **Items and reminders:**
  - `~/Library/Application Support/Cue/items.json`, with a `schemaVersion`
  - written atomically, keeping a `.bak` of the previous version
- **Run history:** in `…/Cue/runs/<itemID>/`.
  - The last 20 runs per item: start and end times, exit code, result, reason, and the output if `keepOutput` is on.
  - Settings has a Clear History button.
- **Secrets:**
  - stored in the Keychain: service `Cue`, account `<itemID>.<KEY>`
  - never written to the JSON, logs, notifications or exports
- **`…/Cue/running.json`:** the process group ID, PID, start time and item ID of each process Cue owns. Used to recover after a crash (section 12).

---

## 12. Quit, relaunch, sleep and crashes

- **Quit while Cue-owned processes are running:**
  - An alert names them (`Splash Server and 1 task are still running`).
  - Buttons: **Stop and Quit** and **Cancel**; Cancel is the default.
  - Services owned by another manager are left running, and the alert says so.
- **Relaunch:**
  - Check everything again. Never show saved states as current.
  - Never start or re-run anything automatically.
  - A task cut off by a crash shows `Outcome unknown · Cue quit during the run`.
- **Orphaned processes:** at launch, check each entry in `running.json`.
  - If its PID is alive and the start time matches, show it as `On · from last session`. Cue still owns it and can stop it.
  - Remove all other entries.
- **No automatic restart** of services in this version; report unexpected exits instead.
- **Sleep:** Cue doesn't prevent it.

---

## 13. Stack and project layout

- **Language and UI:** Swift and SwiftUI, with AppKit where needed (`NSStatusItem`, `NSPanel`, drag and drop). `@Observable` models; process management in an actor.
- **macOS version:** minimum macOS 14; if this Mac runs something newer, use its major version as the deployment target.
- **Project:** defined with **XcodeGen** (`project.yml`) and built with `xcodebuild` from the command line.
- **Targets:**
  - **`CueCore`:** a local Swift package with no UI, containing:
    - models, store, classifier, reminder parser
    - runner, checks, environment capture, redaction
    - its own tests
  - **`Cue`:** the app.
    - `LSUIElement = YES`, so there's no Dock icon.
    - Not sandboxed; signed to run locally.
- **Dependency:** `KeyboardShortcuts` (by Sindre Sorhus) for the global hotkey. Nothing else without asking.
- **Launch Cue at login:** via `SMAppService.mainApp`, as a Settings toggle that is off by default.

---

## 14. Look and feel

Native, quiet and warm. The interactive prototype lives at https://claude.ai/code/artifact/8b99b9a5-7472-4337-bc4e-a1199a7b6602. You probably can't open it, so this section carries what matters. If `docs/design/` contains exported prototype files, use them as visual reference only and don't port their code.

### Sizes

- **Panel:** 340 pt wide, 14 pt corner radius.
  - Background: the system material, or a solid color when Reduce Transparency is on.
  - A 0.5 pt edge and a soft shadow.
- **Search field:** 48 pt tall, 15 pt text.
- **Rows:**
  - 48 pt tall, a 6 pt inset around the list, a 9 pt corner radius on the selection
  - tile: 26 pt, 7 pt radius, 15 pt symbol
  - title: 13 pt medium
  - subtitle: 11.5 pt secondary, with tabular digits; monospaced when it shows a command
  - accessory: 30 pt, holding 16 pt glyphs
- **Footer:** 40 pt tall, 12 pt text, key hints in small rounded chips.
- **Group labels:** 11 pt semibold, secondary color.

### Colors

| Token | Light | Dark |
|---|---|---|
| ink | #231E1A | #F2ECE6 |
| ink-2 (secondary) | #655B53 | #B5AAA0 |
| ok | #2E8A57 | #55C68A |
| warn | #B9740F | #E5A445 |
| err | #C8392F | #F06A60 |
| unknown | #8A8079 | #8F857C |
| accent | #6B4FBB | #6B4FBB fill, #B7A2F2 text |

| Tint | Light (tile / symbol) | Dark (tile / symbol) |
|---|---|---|
| sky | #DCEAF2 / #2C6A88 | #1E3440 / #8DC3DC |
| rose | #F4DEE3 / #9C4059 | #41252D / #E79AAE |
| amber | #F4E5CB / #8C5C15 | #3E3020 / #E2B66C |
| sage | #DDE9DE / #3B6E4B | #22342A / #92C7A0 |
| plum | #E6DFF4 / #5B44A0 | #2F2745 / #BAA7EF |
| sand | #ECE3D8 / #6A5A4A | #38312A / #CBB9A4 |

### State glyphs

| State | Glyph |
|---|---|
| Off | a 1.5 pt ring |
| Starting | an arc spinning once every 0.9 s over a faint track |
| On | a solid dot that pulses once when the service turns on |
| Stopping | an arc spinning backwards around a small square |
| Failed | a filled circle with a white `!` |
| Unknown | a dashed ring with a center dot |
| Checking | the Starting arc, in the unknown color |

- Glyphs pop in over 0.26 s when the state changes.
- **Color is never the only signal:** every state has its own shape.

### Motion

- The panel opens in 0.24 s with a slight scale.
- The selection highlight slides between rows.
- Inline expansions grow in place.
- **With Reduce Motion on:** fades only, and spinners become static arcs.

---

## 15. Milestones

Each milestone ends with: it builds, tests pass, it's committed, and I get a checklist to try it.

**M0 · Skeleton and spikes**

- A menu-bar-only app from the XcodeGen project.
- `NSStatusItem` plus a nonactivating `NSPanel` hosting SwiftUI, with:
  - focus in a search field
  - closing on Esc or a click outside
  - the global hotkey
- The `CueCore` package with one passing test.
- Two spikes, each with tests:
  - spawn a process group and kill the whole tree: after stopping `sh -c 'sleep 60 & sleep 60; wait'`, no process survives;
  - capture the login-shell environment while the shell prints startup noise.
- **Done when:**
  - the panel opens over another app without taking focus away from that app;
  - typing goes into the search field;
  - both spike tests pass.

**M1 · Core**

- Models and the JSON store.
- The runner actor: spawning, the output buffer, `::cue` lines, stop, time limits, duplicate protection, exit-code messages, redaction.
- The three checks, with the exit-code rule from section 3.
- The state machine from section 3.
- Unit tests for every transition, using fixture scripts and a TCP listener created inside the test. No Docker or network needed.

**M2 · Panel**

- Rows, glyphs and the one-click table.
- Footer, ⌘K menu, keyboard and search.
- Inline expansions: inputs, error details, run details, confirmation.
- Empty state, menu-bar icon states, dimming of stale glyphs.
- For now, items can come from a hand-written `items.json`.

**M3 · Editor and Test Run**

- Everything in section 7.
- Keychain secrets.
- The Not-yet-tested signature.
- Reordering, adding and removing items.

**M4 · Quick add**

- Everything in section 6:
  - classification with PATH lookup, the add row with Tab
  - ⌘↵ run once and the Recent group
  - drops on the panel and the icon, Make executable
  - Needs Terminal and Run in Terminal
- Classifier tests must include:

  | Input | Expected |
  |---|---|
  | `splash serve` (with a fake `splash` on a test PATH) | Command |
  | `water the plants` | Reminder, no time |
  | `npm test -- --watch` | Command |
  | `localhost:4000/admin` | Link |
  | `call the bank at 18:30` | Reminder at 18:30 |

**M5 · Reminders**

- Everything in section 10.
- Parser tests, including past times rolling over to tomorrow and 12 am / 12 pm edge cases.
- Write `docs/WRITING-TOOLS.md` (section 16).

**M6 · Reliability**

- The check schedule from section 9 and wake handling.
- Quit alert, relaunch behavior, orphaned processes.
- Port-conflict check before starting, owner lookup, and Stop process on port….
- Notifications:
  - a task that finished (only if the panel is closed and the run took more than 5 s)
  - every failure
  - unexpected exits
- The View Log window: read-only, monospaced, with Copy and Reveal in Finder.
- History limits.
- A check of the whole library at launch: a missing folder, a missing script, or a program that can't be found marks the item as needing attention.

**M7 · Polish**

- A Settings window: hotkey, captured environment with Refresh, launch Cue at login, reminder sound, history.
- VoiceOver labels, e.g. `Splash Server, running for 4 minutes, localhost:4000. Stop.`
- Reduce Motion, Reduce Transparency, Increase Contrast.
- Light and dark appearances checked against the tokens.
- Animation tuning.

---

## 16. `docs/WRITING-TOOLS.md` (a guide for me)

Explain, with short examples:

- how inputs arrive as environment variables;
- the `CUE=1` variable;
- the `::cue result` and `::cue reason` lines;
- the status-command exit codes.

Include this Docker example:

```sh
# Exit 0 = running, 1 = stopped, 2 = Docker unreachable (shown as Unknown)
docker info >/dev/null 2>&1 || exit 2
[ "$(docker inspect -f '{{.State.Running}}' web-db 2>/dev/null)" = true ] && exit 0 || exit 1
```

Also explain why `docker ps -q -f name=web-db` makes a bad check: it exits 0 even when no container matches.

---

## 17. Later (don't build yet, but don't make these hard to add)

- Shortcuts and Spotlight actions via App Intents (one generic "Run Cue item" action)
- A Control Center control for a favorite service
- Global shortcuts for individual items
- Send to Apple Reminders (EventKit)
- Named presets, and changing an input for one run only
- "Wait until" checks
- Delayed runs (`run X at 23:00`) and service timers (`start for 1 hour`)
- Small routines that start several items together
- "What changed since last run" for status-like scripts
- File and clipboard inputs
- Import and export of items
- Items stored as script files with a Raycast-compatible header
- A gentle prompt to stop running services when a chosen app (e.g. my DAW) launches

---

## 18. Out of scope

- A terminal emulator, or interactive commands beyond Run in Terminal
- Recurring schedules or a cron editor
- Accounts, sync, subscriptions
- AI at runtime
- A plugin system
- Docker management beyond start, stop and check
- Restarting services automatically
- Watching the clipboard
- CPU or memory graphs
- Mac App Store sandboxing
- A "Start at login" option for items: anything that should always run belongs in launchd or `brew services`

---

## 19. Open questions (ask me when you reach them, not before)

- **M5:** should reminders reach my iPhone? Default: in-app only.
- **M2:** if the list grows past about 20 items, do I want a pinned section? Default: a flat list plus search.
