# Serif

A Mac app that keeps Claude Code and Codex bots running, grouped by project, and shows each one as a chat. The real terminal of
every bot is one click away.

Three programs live in one bundle, `Serif.app/Contents/MacOS`:

| Program | Role |
|---|---|
| `Serif` | The window. Talks to the engine; registers itself and the engine as login items. |
| `serifd` | The engine (launchd agent `com.serif.engine`). Keeps every bot's agent alive — Claude Code in its own terminal, Codex on a server of its own —, stores the chats, answers the app. Keeps running when the app is closed. |
| `serif-hook` | Run by Claude Code for every hook; relays it to the engine and, for permissions, waits for the answer. |

## Install on another Mac

Needs macOS 26 on Apple Silicon, and Claude Code installed and signed in (run `claude` once in Terminal). Codex bots also need Codex, signed in: the ChatGPT app (it carries the Codex CLI) or the Codex CLI, then `codex login` once in Terminal.

1. Download `Serif-<version>.dmg` from the [latest release](https://github.com/p-diego/serif/releases/latest).
2. Open it and drag Serif into Applications.
3. Open Serif. The build is signed but not notarized, so the first time macOS refuses it: open System Settings ›
   Privacy & Security and choose Open Anyway.
4. Allow the background item (the engine) when macOS asks. The first time, Serif checks that Claude Code is installed and
   signed in, explains notifications and helps you create your first project and bot.

If the bots stay offline after that, macOS is still holding the engine in quarantine: run
`xattr -dr com.apple.quarantine /Applications/Serif.app` and open Serif again.

From then on Serif updates itself. At launch and once a day it asks GitHub for the latest release; when there is a newer
one, "Update to …" appears at the bottom of the sidebar (Serif › Check for Updates… asks right away). Updating downloads
the zip, checks it is signed like the running copy, replaces the app, restarts the engine (the bots resume their
conversations) and reopens Serif; if some bots are working it asks first, since their reply stops.

## First launch

With no project yet, Serif opens on four steps: a welcome; the agents, checked by the engine: Claude Code (`claude --version`,
`claude auth status`), required, with the install command or the sign-in hint when something is missing, and Codex (`codex --version`,
`codex login status`), optional, with where to get it; Retry checks again; notifications; the first project, after which the
New bot sheet opens. The steps end once the first bot is created.

A new bot introduces itself, in the Mac's language, in its first turn (the chat shows "Serif asked <bot> to introduce
itself", not a message from you); the first bot of a project also gives a short tour. If a bot's agent is later missing or
signed out, the bot stops and its chat shows the same check with Retry.

## Skills, plugins and connectors

Each bot, and each project for all its bots, can be given:

- skills, from `~/.claude/skills` (yours and those synced from claude.ai) or any folder with a `SKILL.md`. Before every
  launch the engine links them into `bots/<id>/workspace/.claude/skills/` and `projects/<id>/shared/.claude/skills/`, so an
  updated skill reaches the bots. Serif manages only those links: folders a bot writes there itself stay;
- plugins, installed (`~/.claude/plugins/installed_plugins.json`) or synced from claude.ai (the newest copy), each passed
  whole with `--plugin-dir`;
- claude.ai connectors: off by default (`ENABLE_CLAUDEAI_MCP_SERVERS=false` in the bot's environment); one switch per bot turns them all on.

A skill or plugin no longer on the Mac shows struck through and is left out. Changing skills, plugins or connectors restarts
the bot, or all the project's bots, and the conversation resumes. Project settings: right click on the project's name in
the sidebar. The New bot sheet starts from Blank or a ready-made bot (Developer, Reviewer, Researcher, Writer) that fills
the name, face, instructions, freedom and the suggested skills and plugins found on this Mac.

## Codex bots

The agent is chosen when a bot is created and never changes. A Codex bot gets a Codex app-server of its own (`codex
app-server` on `ws://127.0.0.1:<free port>`, with a secret new at every launch), started in the bot's folder; its conversation
is a Codex thread, resumed at every launch with all its settings again. The chat comes from the server's events; approvals
and questions are cards with the choices Codex offers, answered in the chat or in the terminal (the first answer wins). The
real terminal (`codex resume … --remote`) runs only while the Terminal view is open, from the bot's first turn.

Freedom becomes Codex's approval and sandbox: Asks permission = `on-request` + `read-only`; Edits files on its own =
`on-request` + `workspace-write`; Automatic = `never` + `workspace-write`. The folders it may write in are its own, the
project's and the linked one.

- skills: the Claude Code list plus `~/.codex/skills` and `~/.agents/skills`, linked with the project's into
  `bots/<id>/workspace/.agents/skills/`;
- plugins: Codex's installed plugins, listed by a short-lived Codex server of the engine's; every installed plugin not chosen
  for the bot or its project starts off; the account's remote plugins cannot be turned off one by one, their skills are hidden;
- connectors: the ChatGPT account's (they include its web search), off by default.

Codex is `SERIF_CODEX`, else `codex` on the login shell's `PATH`, else the ChatGPT app's own copy
(`/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`, updated with the app).

## Requirements

- macOS 26, Xcode with Swift 6.2 or later.
- The Metal Toolchain: SwiftTerm compiles Metal shaders and the first build fails without it. Install it once with
  `xcodebuild -downloadComponent MetalToolchain` (about 840 MB).
- Claude Code installed (`~/.local/bin/claude`, Homebrew, or anywhere on the login shell's `PATH`).
- Codex (optional, for Codex bots): the ChatGPT app or the Codex CLI, signed in.

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

Notifications are asked for in the first-launch steps ("Enable notifications"); with "Not now", macOS asks the first time a
bot waits for you.

## Data and logs

Everything lives in `~/Library/Application Support/Serif/` (or `$SERIF_HOME`):

```
serifd.sock, hook.sock     sockets between app, engine and serif-hook
serifd.log                 engine log (errors only)
state.json                 projects and bots
projects/<id>/shared/      folder shared by the bots of a project
bots/<id>/workspace/       the bot's working folder (its memory is CLAUDE.md there, AGENTS.md for a Codex bot)
bots/<id>/workspace/.claude/skills/        links to the bot's skills
bots/<id>/workspace/.agents/skills/        links to a Codex bot's skills (its own and its project's)
projects/<id>/shared/.claude/skills/       links to the project's skills
bots/<id>/events.jsonl     the chat history, one event per line
bots/<id>/codex.log        a Codex bot's server output, rewritten at every launch
codex-catalog.log          output of the server that lists Codex's plugins and models
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
- one `--plugin-dir` per plugin of the bot and its project, and `ENABLE_CLAUDEAI_MCP_SERVERS=false` in its environment unless the bot's connectors are on;
- an environment without `CLAUDE*` variables and without `ANTHROPIC_API_KEY` (bots use the subscription), with the login
  shell's `PATH` so they find the user's tools.

Each Codex bot's server runs with:

- `--disable hooks` and `-c notify=[]`: Siigil's hooks and the user's notify program never run for a bot;
- `-c plugins.<id>.enabled=false|true` for every installed plugin, `-c skills.config=…` hiding the skills of the remote plugins
  not chosen, and `--disable apps` unless the bot's connectors are on;
- an environment without `CLAUDE*` variables, `ANTHROPIC_API_KEY` and `CODEX_THREAD_ID`.

All of it is on the command line: a thread's `config` would replace it key by key, so Serif's holds only the folders the bot
may write in. Right after the thread opens the engine asks Codex whether the hooks are off and, with connectors off, whether
the account's connectors are gone; if not, the bot does not run ("Isolation not guaranteed").

Full isolation with a separate Claude Code configuration folder is planned for a later version.

## License

Serif is open source under the [MIT License](LICENSE).
