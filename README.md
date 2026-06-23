
<img width="672" height="80" alt="Screen Recording 2026-06-23 at 3 57 47 AM 2" src="https://github.com/user-attachments/assets/97876ac9-cd4f-431b-873a-93220de5bd99" />

<br>

## Claude Status Bar

A tiny macOS menu bar app that shows **Claude Code's live status**: an animated Claude spark while it's thinking or running a tool, a yellow dot when it's awaiting your permission, and the elapsed time of the current turn. Lightweight, no window, no dock icon, no usage dashboards.

_Built so you can tab away during a long "thinking" stretch and still see, at a glance, whether Claude is working, waiting on you, or done._


<img width="1016" height="566" alt="Claude Status Bar demo" src="https://github.com/user-attachments/assets/55a7b294-e893-4f73-b16b-b8beef784400" />

<br><br>

<a href="https://github.com/m1ckc3s/claude-status-bar/releases/latest/download/ClaudeStatusBar.dmg"><img src="assets/download.png" alt="Download ClaudeStatusBar.dmg for macOS" width="260"></a>

<br>

Signed and notarized. Open it, drag the app to Applications, launch once.

---

## What it shows

- **Thinking / working** — the Claude spark animates, with a live `1m 1s` timer.
- **Running a tool** — a short label (`Editing`, `Reading`, `Running command`, `Using tool`, …).
- **Awaiting permission** — a paused yellow dot (CLI only, see below).
- **Idle / done** — rests on the Claude logo.

Everything is controlled from the menu:

- **Show timer:** toggle the elapsed `1m 1s` clock.
- **Play completion sound:** a soft chime when a turn longer than a minute finishes (off by default).
- **Animation style:**
  - **Claude**, the web "morph" spark
  - **Claude Code**, the terminal glyph spinner
  - **Crab Walking**, a pixel-art Clawd crab that scuttles while Claude works
- **Icon color:** **Orange** or **System** (adaptive black/white). The Claude and Claude Code styles follow this setting; Crab Walking is always its orange pixel-art self.
- **Version and update:** the menu shows your current version, with a one-click "Update available" when a newer release exists.

## Where it works

| Surface | Tracked? |
|---|---|
| Claude Code CLI (terminal) | ✅ |
| Claude Code Desktop — **Code** tab | ✅ |
| Claude Desktop — **Chat** tab | ❌ |
| **Cowork** | ❌ |

Chat and Cowork don't use Claude Code's hook system, so the status bar won't update while you're in those. It reflects Claude **Code** activity only.

### Permission detection is CLI-only

🟡 The yellow "Awaiting permission" dot appears when Claude Code fires its permission *notification*, which it does in the **CLI**. 
The **Desktop app** doesn't emit that hook for its in-app permission prompts, so the dot won't show there, the icon just stays on the current tool (e.g. "Writing") while the prompt is open. Everything else (thinking, tools, the open/close lifecycle) works the same in both.

## Requirements

- macOS 12+
- [Claude Code](https://claude.com/claude-code) (CLI or the Desktop app)
- Node.js (used by the hook scripts)

## Install

### Option A — DMG (recommended)

1. Download the latest `ClaudeStatusBar.dmg` from [Releases](../../releases).
2. Open it and drag **Claude Status Bar** into Applications.
3. Launch it once. On first launch it wires up the Claude Code hooks for you automatically. (Already had a previous version? You can skip this, just open Claude Code and it updates itself.)
4. Start a new Claude Code session, the spark appears whenever Claude Code is running.

### Updating to a new version?

1. Download the latest `ClaudeStatusBar.dmg` from [Releases](../../releases).
2. Open it and drag **Claude Status Bar** into Applications. Finder will say an item with that name already exists and ask what to do, choose **Replace**. You do not need to uninstall the old version first.
3. Launch it once. On a version change it refreshes its hooks automatically and cleans up anything an older version left behind, so there's no manual step.
4. Restart Claude Code (or start a new session) so it picks up the refreshed hooks.

### Option B — Claude Code plugin

Installs the hooks (status + open/close lifecycle) automatically from inside Claude Code:

```
/plugin marketplace add m1ckc3s/claude-status-bar
/plugin install claude-status-bar@claude-status-bar
```

The plugin installs the hooks but not the app itself, so drag **Claude Status Bar** into Applications once (from the DMG). The plugin launches it automatically on session start.

## How it works

Claude Code fires hooks on its lifecycle and tool events. Small scripts write the current status to `~/.claude/statusbar/state.json`; the menu bar app polls that file and renders the spark + label. The `SessionStart` hook launches the app when Claude Code opens (in the terminal, the desktop app, or a new conversation). The app then quits itself once Claude is gone, that is, when the Claude desktop app isn't running and no Claude Code session is active. Active sessions are tracked as one small file each under `~/.claude/statusbar/sessions.d/`, so any working session keeps the bar up.

The installer merges its hooks into `~/.claude/settings.json` without touching your existing hooks, and backs the file up first (`settings.json.bak-statusbar`).

## Privacy

Claude Status Bar collects no data and has no servers. It runs entirely on your Mac. Its one network call is a once-a-day check to GitHub's public API for the latest release tag, used only to show "Update available" in the menu. Nothing is sent to the developer (as with any update check or download, GitHub sees the request; the developer never does).

## Uninstall

```bash
node "/Applications/ClaudeStatusBar.app/Contents/Resources/uninstall.js"   # removes only our hooks
```
Then drag the app to the Trash.

## Build from source

```bash
git clone https://github.com/m1ckc3s/claude-status-bar
cd claude-status-bar
./build.sh            # builds build/ClaudeStatusBar.app
./build.sh --dmg      # also produces build/ClaudeStatusBar.dmg
```
Requires the Xcode Command Line Tools (`xcode-select --install`).

## Troubleshooting

You don't launch the app yourself; the session launches it.

**The icon doesn't appear at all?**
- Make sure a Claude session is actually running. Start a new session (or restart Claude Code) and the bar appears automatically.
- A session that was already running *before* you installed gets picked up once it does something, but starting a fresh session is the reliable way to bring the bar up the first time.
- Confirm it's running with `pgrep -x ClaudeStatusBar`: a number means it's running (it may just be hidden) no output means it exited because no Claude session is active.
- If first-launch setup never took, run the installer manually: `node "/Applications/ClaudeStatusBar.app/Contents/Resources/install.js"`
- Seeing 2 icons? The desktop app shows its own menu bar icon (the quick-screenshot one). To avoid two icons sitting side by side, open Claude's **Settings → General** and turn that built-in menu bar item off.

## Trademark / not affiliated

This is an unofficial, open-source side project. **It is not affiliated with, endorsed by, or sponsored by Anthropic.** "Claude" and the Claude logo are trademarks of Anthropic.

If I'm violating or impeding your trademark, DM me on X ([@mickces](https://x.com/mickces)) and I'll rename this repo. 
This is a free side project; I'm not monetizing it.

## License

MIT
