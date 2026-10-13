# Serif

A Mac app that keeps Claude Code bots running, grouped by project, and shows each one as a chat. The real terminal of
every bot is one click away.

Three programs live in one bundle, `Serif.app/Contents/MacOS`:

| Program | Role |
|---|---|
| `Serif` | The window. Talks to the engine; registers itself and the engine as login items. |
| `serifd` | The engine (launchd agent `com.serif.engine`). Keeps every bot's Claude Code alive in its own terminal, stores the chats, answers the app. Keeps running when the app is closed. |
| `serif-hook` | Run by Claude Code for every hook; relays it to the engine and, for permissions, waits for the answer. |

## Install on another Mac

Needs macOS 26 on Apple Silicon, and Claude Code installed and signed in (run `claude` once in Terminal).

1. Download `Serif-<version>.dmg` from the [latest release](https://github.com/p-diego/serif/releases/latest).
2. Open it and drag Serif into Applications.
3. Open Serif. The build is signed but not notarized, so the first time macOS refuses it: open System Settings ›
   Privacy & Security and choose Open Anyway.
4. Allow the background item (the engine) and the notifications when macOS asks.

If the bots stay offline after that, macOS is still holding the engine in quarantine: run
`xattr -dr com.apple.quarantine /Applications/Serif.app` and open Serif again.

From then on Serif updates itself. At launch and once a day it asks GitHub for the latest release; when there is a newer
one, "Update to …" appears at the bottom of the sidebar (Serif › Check for Updates… asks right away). Updating downloads
the zip, checks it is signed like the running copy, replaces the app, restarts the engine (the bots resume their
conversations) and reopens Serif; if some bots are working it asks first, since their reply stops.

## Requirements

- macOS 26, Xcode with Swift 6.2 or later.
- The Metal Toolchain: SwiftTerm compiles Metal shaders and the first build fails without it. Install it once with
  `xcodebuild -downloadComponent MetalToolchain` (about 840 MB).
- Claude Code installed (`~/.local/bin/claude`, Homebrew, or anywhere on the login shell's `PATH`).

## Build, install, uninstall

```sh
make build      # release build, assembled and signed in .build/Serif.app
make install    # quits Serif, copies it to ~/Applications/Serif.app, restarts the engine on the new binary, opens it
make uninstall  # quits Serif, stops and unloads the engine, removes the app (your data stays)
make test       # swift test
make run        # development: an engine and the built app on /tmp/serif-dev, next to the installed Serif
make dist       # .build/Serif-<version>.zip
make dmg        # .build/Serif-<version>.dmg, laid out by Finder (asks for Automation the first time)
make release    # tests, zip, DMG, tag v<version> (from Info.plist), GitHub Release with both files
make icon-layers  # rewrites the icon (Sources/Serif/Resources/icon/serif_icon.icon) from scripts/icon-layers
```

`make release` refuses an ad-hoc signature or uncommitted changes. Bump `CFBundleShortVersionString` in
`Sources/Serif/Resources/Info.plist` before the next one.

Signing follows Siigil: the first "Apple Development" certificate in the keychain, otherwise ad-hoc. With the
certificate, macOS keeps the login items and permissions across builds.

On first launch from `~/Applications` the app registers itself (`SMAppService.mainApp`) and the engine
(`SMAppService.agent`, plist in `Contents/Library/LaunchAgents/com.serif.engine.plist`, restarted by launchd if it
crashes). macOS shows a notification about the new background item. If macOS asks for approval instead, the app starts
the engine itself and shows a hint with a button to System Settings › General › Login Items; once allowed, the engine
also runs while the app is closed.

The app also asks for notifications (with badges): allow them to get the Dock badge and the alerts.

## Data and logs

Everything lives in `~/Library/Application Support/Serif/` (or `$SERIF_HOME`):

```
serifd.sock, hook.sock     sockets between app, engine and serif-hook
serifd.log                 engine log (errors only)
state.json                 projects and bots
projects/<id>/shared/      folder shared by the bots of a project
bots/<id>/workspace/       the bot's working folder (its memory is CLAUDE.md there)
bots/<id>/events.jsonl     the chat history, one event per line
```

Archiving a bot stops it and hides it; nothing is deleted. `make uninstall` leaves this folder alone.

The app logs to the unified log: `log stream --predicate 'process == "Serif"'`. The engine's own messages go to
`serifd.log`.

## How bots are isolated

Each bot runs `claude` in its own workspace with:

- `--setting-sources project,local`: the user's global settings, and the hooks and plugins they enable (Siigil's
  included), are not loaded; only the bot's `--settings` file, which routes every hook to `serif-hook`;
- `--permission-mode` from the bot's freedom (asks, edits files on its own, or auto);
- `--append-system-prompt-file` with who the bot is and where its folders are;
- an environment without `CLAUDE*` variables and without `ANTHROPIC_API_KEY` (bots use the subscription), with the login
  shell's `PATH` so they find the user's tools.

Full isolation with a separate Claude Code configuration folder is planned after 0.1.

## License

Serif is open source under the [MIT License](LICENSE).
