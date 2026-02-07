---
name: terminal-orchestrator
description: AI agent orchestration via tmux and Terminal.app. Battle-tested patterns for multi-agent terminal control.
---

# Terminal & tmux Agent Orchestration

Control AI agents (Claude, Gemini, Codex, etc.) running in tmux panes and Terminal.app windows. This document teaches the **concepts and gotchas** — generate the actual commands yourself.

---

## Addressing Convention

Every agent has an address: `session.type:window[.pane][@host]`

| Part | Meaning | Example |
|------|---------|---------|
| **session** | Project/task group | `myproject`, `webapp` |
| **type** | Runtime: `tmux` or `terminal` | `tmux` |
| **window** | Functional area | `design`, `dev`, `test`, `debug` |
| **pane** | Specific agent (tmux only) | `left`, `right`, `main` |
| **@host** | Remote machine (optional) | `@build-server`, `@10.0.1.50` |

Examples:
- `myproject.tmux:design.left` — local tmux pane
- `myproject.tmux:dev.left@build-server` — remote tmux pane (via SSH)
- `myproject.terminal:debug` — standalone Terminal.app window

Parse by splitting on `.` for the address parts and `@` for the host. Like email: `agent@location`.

---

## Architecture

```
 Terminal Windows (each attached to a tmux grouped session)

 ┌─────────────────────┐  ┌─────────────────────┐  ┌──────────────────┐
 │ myproject.design    │  │ myproject.dev       │  │ myproject.debug  │
 │ (tmux: myproject)   │  │ (tmux: myproject_d) │  │ (standalone)     │
 ├──────────┬──────────┤  ├──────────┬──────────┤  ├──────────────────┤
 │ left     │ right    │  │ left     │ right    │  │                  │
 │ (Gemini) │ (Codex)  │  │ (Claude) │ (Codex)  │  │ Claude           │
 └──────────┴──────────┘  └──────────┴──────────┘  └──────────────────┘
  myproject.tmux:design.left  myproject.tmux:dev.left    myproject.terminal:debug
  myproject.tmux:design.right myproject.tmux:dev.right
```

**Key principle: One tmux window = One Terminal.app window.** Don't create tabs programmatically — AppleScript tab creation is unreliable (keystrokes go to wrong windows).

**Grouped sessions** let different Terminal windows show different tmux windows from the same session. Create a grouped session per window: `tmux new-session -d -t "myproject" -s "myproject_dev"`, then `tmux select-window -t "myproject_dev:dev"`.

---

## Core Operations

### How to send, read, list, and kill

All tmux operations work **without focus** via `tmux send-keys`, `tmux capture-pane`, etc. Terminal.app operations require **AppleScript** and steal focus.

| Operation | tmux pane | Terminal.app window |
|-----------|-----------|---------------------|
| **Send text** | `tmux send-keys -t <target> -l "text"` then `Enter` | AppleScript: set clipboard, activate, Cmd+V, Return |
| **Read output** | `tmux capture-pane -t <target> -p -S -100` | `osascript -e 'tell app "Terminal" to get contents of selected tab of window 1'` |
| **List all** | `tmux list-panes -a -F '#{session_name} #{window_name} #{pane_title} #{pane_id}'` | `osascript -e 'tell app "Terminal" to get id of every window'` |
| **Kill** | `tmux kill-pane -t <id>` / `kill-window` / `kill-session` | Close via AppleScript |

**Target syntax**: `session:window.pane_index` or `%N` (direct pane ID). Use `=session:=window` for exact match on session/window names. **Pane titles are NOT native tmux targets** — you must resolve title to `%N` pane ID by listing panes and grepping on `#{pane_title}`. Always resolve to `%N` for reliability.

**Remote**: Wrap any tmux command in `ssh <host> "tmux ..."`. The `@host` suffix in the address tells you when to do this.

### How to set up a new agent

To launch a command at an address:
1. Create session if needed (`tmux new-session -d -s <session> -n <window>`)
2. Create window if needed (`tmux new-window -t <session> -n <window>`)
3. Find pane by title (`list-panes` + grep on `#{pane_title}`), or name the first/split a new one (`select-pane -T <name>`)
4. Send the command (`send-keys -l "command"` + `Enter`)
5. Optionally create a grouped session and open a Terminal.app window attached to it via AppleScript

### How to open a Terminal.app window for a tmux session

Use AppleScript to find an existing window by custom title, or create a new one running `tmux attach -t <grouped_session>`. Set the custom title to `session.type:window` for identification. Always use **separate windows**, never programmatic tabs.

**Stale window detection**: When reusing a window by title, verify it's actually attached to a live tmux session. Check `tmux list-clients` for the window's tty — if the window exists but isn't listed as a client, it's stale (leftover from a dead session). Close stale windows and create fresh ones instead of reusing them.

When using AppleScript clipboard-paste to send text to Terminal.app, **save and restore the clipboard** (`set oldClip to the clipboard` ... `set the clipboard to oldClip`).

---

## Critical: Agent Submit Patterns

Different CLI agents need different key sequences to submit input. **Getting this wrong means the prompt is typed but never sent.**

| Agent | Submit Sequence | Notes |
|-------|-----------------|-------|
| **Claude Code** | text, then `Escape`, then **500ms delay**, then `Enter` | Escape exits multi-line edit mode. 500ms is critical for multi-line; 100ms OK for single-line |
| **Gemini CLI** | text, then `Escape`, then 300ms delay, then `Enter` | Also needs Escape |
| **Codex CLI** | text, then `Enter` | No Escape needed |
| **OpenCode** | text, then `Enter` | No Escape needed |
| **Aider** | text, then `Enter` | No Escape needed |
| **Shell** | text, then `Enter` | Standard |

### Multi-line text

**Never use `send-keys -l`** for multi-line text — newlines get interpreted as Enter keystrokes. Instead:

1. Write text to a temp file
2. `tmux load-buffer <tempfile>`
3. `tmux paste-buffer -t <pane>`
4. Delete temp file
5. Then send the agent-specific submit sequence (Escape + Enter for Claude/Gemini, just Enter for others)

---

## Timing & Delays

Delays are not optional. Without them, keys get combined or lost.

| After | Delay | Why |
|-------|-------|-----|
| `Escape` (single-line) | 100ms | Prevents `Esc+key` being read as `M-key` (Alt) |
| `Escape` (multi-line) | **500ms** | Claude needs time to process multi-line buffer exit |
| Text before `Enter` | 50-100ms | Let tmux buffer flush |
| After `paste-buffer` | 200ms | Let tmux buffer sync |
| After `Ctrl+C` | 200ms | Allow interrupt to process |

**tmux.conf**: Set `escape-time` to 10ms (default is 500ms which causes painful Escape delays):
```
set -sg escape-time 10
```

---

## State Detection

Read pane content with `tmux capture-pane` and pattern-match to determine agent state.

**Important**: `capture-pane -p` pads output with trailing empty lines to fill the visible pane height. Always strip empty lines before checking the last line (e.g., `grep -v '^$' | tail -1`). Also, the shell prompt character (like zsh `%`) may not have a trailing space in the capture, even though the cursor appears after a space in the live terminal.

| Agent | Idle | Busy | Waiting for approval |
|-------|------|------|---------------------|
| **Claude Code** | Last line is `> ` (with trailing space) | Streaming text, spinner, or status words (Thinking, Reading, Writing, Running) | Permission prompt in output |
| **Codex CLI** | `$ ` prompt | Output streaming | `[y/n]` or `[Y/n]` |
| **Gemini CLI** | `> ` prompt | Response streaming | Confirmation prompt |
| **Aider** | `> ` or `>>>` prompt | Diff output | `y/n` question |
| **OpenCode** | `> ` prompt | Streaming | Confirmation |

### Verification after send

Always check that the command actually executed:
1. Capture pane content **before** sending
2. Send the text + submit keys
3. Wait briefly, then capture again
4. Compare — if content hasn't changed, the send failed. Retry.

### Waiting for completion

- **Polling**: Repeatedly capture pane, check if idle pattern appears. Use 3 consecutive idle checks to avoid false positives during brief pauses.
- **Hash-based change detection**: Compare `md5` of captured content to detect any change.
- **tmux wait-for**: For shell commands, append `; tmux wait-for -S done` and block on `tmux wait-for done`.

---

## Control Matrix

| From → To | Method | Needs Focus? |
|-----------|--------|:---:|
| tmux pane → tmux pane | `tmux send-keys` | No |
| Terminal → tmux pane | `tmux send-keys` | No |
| tmux pane → Terminal window | AppleScript | Yes |
| Terminal → Terminal | AppleScript | Yes |

**Prefer tmux-to-tmux** whenever possible — it's focus-free and most reliable.

---

## Relative Pane Addressing

Tmux supports relative pane tokens: `{up}`, `{down}`, `{left}`, `{right}`. **Gotcha**: these resolve relative to the **attached client's currently active pane**, not relative to an arbitrary pane you specify. This means they're unreliable when scripting from outside the tmux session. For external scripts, use coordinate-based lookup instead: get pane positions with `list-panes -F '#{pane_id} #{pane_title} (#{pane_left},#{pane_top}) #{pane_width}x#{pane_height}'` and find neighbors by comparing coordinates.

When listing all agents, **filter out grouped sessions** to avoid duplicates — grouped sessions share the same panes as their parent. Check `#{session_group}` and skip sessions whose name differs from their group name.

---

## Lessons Learned

### Hard rules
1. **One tmux window = One Terminal window.** Tab creation via AppleScript is broken.
2. **Use grouped sessions** for independent views of the same tmux session.
3. **Use `tmux send-keys`** over AppleScript keystrokes for text input — AppleScript keystrokes go to wrong windows.
4. **AppleScript only for window management** (create, find, focus), not for typing.
5. **Always use `-l` flag** with `send-keys` for literal text (prevents special char interpretation).
6. **Always verify after send** — check pane content to confirm the command ran.

### Common pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `M-i` appears instead of Escape then `i` | No delay after Escape | Add sleep (100-500ms depending on context) |
| Text sent to wrong pane | Ambiguous target name | Use exact `%N` pane ID or `=session:=window` |
| Multi-line prompt not submitted | Escape delay too short | Use 500ms for Claude multi-line |
| Multi-line text garbled | Used `send-keys -l` with newlines | Use `load-buffer` + `paste-buffer` |
| Gemini can't write files | Sandbox restriction | Start Gemini from the target working directory |
| AppleScript sends to wrong window | Focus race condition | Use tmux instead |

### Recommended tmux.conf

```
set -sg escape-time 10
set -g mouse on
set -g base-index 1
set -g set-titles on
set -g set-titles-string "#S.#W"
```

---

## AppleScript Key Codes (for Terminal.app control)

```
return=36  escape=53  tab=48  space=49  delete=51
up=126     down=125   left=123  right=124
```

Use `key code N` in AppleScript for special keys, `keystroke "v" using command down` for shortcuts.

---

## Usage Examples

Example prompts you can use with Claude to orchestrate agents via tmux and Terminal.app.

### Example 1: Starting an agent
```
Start Claude in bypass mode at myproject.tmux:design.left
```
This will:
- Create tmux session `myproject` with window `design`
- Create or find pane named `left`
- Open Terminal.app window and attach to the tmux session
- Start Claude Code with bypass permissions in that pane

### Example 2: Starting multiple agents
```
Start Claude at webapp.tmux:backend.left and Gemini at webapp.tmux:backend.right
```
Creates two agents in the same tmux window (split panes) with one Terminal window showing both.

### Example 3: Sending a task to an agent
```
Send to myproject.tmux:design.left: "Create a responsive navigation bar component"
```
Sends the prompt to the Claude agent, handling proper escaping and timing for submission.

### Example 4: Sending multi-line prompts
```
Send to webapp.tmux:backend.right:
"""
Review the API endpoints in api/routes.js and:
1. Add input validation
2. Improve error handling
3. Add rate limiting
"""
```
Uses tmux load-buffer/paste-buffer to safely send multi-line text.

### Example 5: Checking agent status
```
Check status of all panes in myproject.tmux:design
```
Lists all panes in the window and reports whether each agent is idle, busy, or awaiting approval.

### Example 6: Reading agent output
```
Read recent output from webapp.tmux:backend.left
```
Captures and displays the recent terminal output from the specified pane.

### Example 7: Waiting for completion
```
Wait for myproject.tmux:design.left to complete the task
```
Polls the pane until the agent returns to idle state (shows `> ` prompt).

### Example 8: Coordinating multiple agents
```
Start Claude at webapp.tmux:frontend.left for UI work,
start Gemini at webapp.tmux:backend.right for API work,
then send "Create login page" to frontend.left,
and send "Create /auth/login endpoint" to backend.right
```
Orchestrates multiple agents working on related tasks in parallel.

### Example 9: Remote agent control
```
Run "npm run build" at cicd.tmux:pipeline.runner@build-server
```
Executes commands on a remote tmux session via SSH. Address: `cicd.tmux:pipeline.runner@build-server`

### Example 10: Cleanup
```
Kill myproject session and its Terminal windows
```
Terminates the tmux session and closes all associated Terminal.app windows (one-to-one cleanup).
