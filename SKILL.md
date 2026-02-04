---
name: terminal-orchestrator
description: AI agent orchestration via tmux and Terminal.app. Battle-tested patterns for multi-agent terminal control.
---

# Terminal & tmux Control

Minimal, battle-tested patterns for mutual control between terminals and tmux.

---

## Architecture: One tmux Window = One Terminal Window

**Important**: Terminal.app tab creation via AppleScript is unreliable. Use separate Terminal windows instead.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Terminal Windows (each attached to a tmux grouped session)                 │
│                                                                             │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐  │
│  │ uart.design         │  │ uart.dv             │  │ uart.debug          │  │
│  │ (tmux: uart)        │  │ (tmux: uart_dv)     │  │ (standalone)        │  │
│  ├──────────┬──────────┤  ├──────────┬──────────┤  ├─────────────────────┤  │
│  │ tx       │ rx       │  │ tx       │ rx       │  │                     │  │
│  │ (Gemini) │ (Codex)  │  │ (Claude) │ (Codex)  │  │ Claude              │  │
│  │          │          │  │          │          │  │                     │  │
│  └──────────┴──────────┘  └──────────┴──────────┘  └─────────────────────┘  │
│   uart.tmux.design.tx      uart.tmux.dv.tx         uart.terminal.debug     │
│   uart.tmux.design.rx      uart.tmux.dv.rx                                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Grouped Sessions for Independent Window Views

tmux sessions share windows. To show different windows in different terminals:
- Main session: `uart` (owns the windows)
- Grouped session: `uart_dv` (shares windows, can select different one)

```bash
# Create grouped session
tmux new-session -d -t "uart" -s "uart_dv"
tmux select-window -t "uart_dv:dv"
```

## Naming Convention: `session.{tmux|terminal}.window[.pane]`

> **Note**: `uart`, `design`, `dv` 等都是示例名称，实际使用时替换为你的项目/任务名。
> 例如：`myproject.tmux.dev.main`, `webapp.tmux.frontend.editor`

### Address = Location (命令单独指定)

| Type | Format | Example |
|------|--------|---------|
| **tmux pane** | `session.tmux.window.pane` | `uart.tmux.dv.tx` |
| **terminal window** | `session.terminal.name` | `uart.terminal.debug` |

### Hierarchy

| Level | tmux | Terminal.app |
|-------|------|--------------|
| **Session** | tmux session (+ grouped sessions) | N/A |
| **Window** | tmux window | Terminal window (title: `session.window`) |
| **Pane** | tmux pane (named) | N/A |

---

## Part 0: Core Commands

### `run` - Launch command at address (auto-opens Terminal)

```bash
run() {
    local cmd=$1
    local addr=$2
    IFS='.' read -r session type window pane <<< "$addr"

    case "$type" in
        tmux)
            # 1. Create main session if needed
            if ! tmux has-session -t "$session" 2>/dev/null; then
                tmux new-session -d -s "$session" -n "$window"
            fi

            # 2. Create window if needed
            if ! tmux list-windows -t "$session" -F '#{window_name}' | grep -qx "$window"; then
                tmux new-window -t "$session" -n "$window"
            fi

            # 3. Find or create pane
            local target="$session:$window"
            local pane_id=$(tmux list-panes -t "$target" -F '#{pane_title} #{pane_id}' 2>/dev/null | grep "^$pane " | awk '{print $2}')

            if [[ -z "$pane_id" ]]; then
                local count=$(tmux list-panes -t "$target" 2>/dev/null | wc -l | tr -d ' ')
                if [[ "$count" -le 1 ]]; then
                    pane_id=$(tmux list-panes -t "$target" -F '#{pane_id}' | head -1)
                else
                    pane_id=$(tmux split-window -t "$target" -h -P -F '#{pane_id}')
                fi
                tmux select-pane -t "$pane_id" -T "$pane"
            fi

            # 4. Run command
            tmux send-keys -t "$pane_id" -l "$cmd"
            sleep 0.05
            tmux send-keys -t "$pane_id" Enter

            # 5. Create grouped session for this window (enables independent view)
            local grouped_session="${session}_${window}"
            if ! tmux has-session -t "$grouped_session" 2>/dev/null; then
                tmux new-session -d -t "$session" -s "$grouped_session"
            fi
            tmux select-window -t "$grouped_session:$window"

            # 6. Auto-open Terminal window (one per tmux window)
            if [[ -z "$TMUX" ]]; then
                local term_title="$session.$window"
                osascript <<EOF
tell application "Terminal"
    set targetWindow to missing value
    repeat with w in windows
        try
            if (custom title of w) is "$term_title" then
                set targetWindow to w
                exit repeat
            end if
        end try
    end repeat

    if targetWindow is missing value then
        set newWin to do script "tmux attach -t $grouped_session"
        delay 1
        set custom title of front window to "$term_title"
        set custom title of selected tab of front window to "$term_title"
    else
        set frontmost of targetWindow to true
    end if
    activate
end tell
EOF
            fi

            echo "→ $addr ($pane_id): $cmd"
            ;;

        terminal)
            # Standalone Terminal window (no tmux)
            local term_title="$session.$window"
            osascript <<EOF
tell application "Terminal"
    set targetWindow to missing value
    repeat with w in windows
        try
            if (custom title of w) is "$term_title" then
                set targetWindow to w
                exit repeat
            end if
        end try
    end repeat

    if targetWindow is missing value then
        set newWin to do script "$cmd"
        delay 1
        set custom title of front window to "$term_title"
        set custom title of selected tab of front window to "$term_title"
    else
        set frontmost of targetWindow to true
    end if
    activate
end tell
EOF
            echo "→ $addr: $cmd"
            ;;
    esac
}
```

### `send` - Send text to address

```bash
send() {
    local addr=$1
    local text=$2
    IFS='.' read -r session type window pane <<< "$addr"

    case "$type" in
        tmux)
            local pane_id=$(tmux list-panes -t "$session:$window" -F '#{pane_title} #{pane_id}' | grep "^$pane " | awk '{print $2}')
            [[ -z "$pane_id" ]] && { echo "Not found: $addr"; return 1; }

            tmux send-keys -t "$pane_id" -l "$text"
            sleep 0.1

            # Claude needs Esc+Return
            local content=$(tmux capture-pane -t "$pane_id" -p -S -5)
            if echo "$content" | grep -qiE 'claude|Claude Code'; then
                tmux send-keys -t "$pane_id" Escape
                sleep 0.1
            fi
            tmux send-keys -t "$pane_id" Enter
            echo "→ $addr: sent"
            ;;

        terminal)
            osascript -e "
                set the clipboard to \"$text\"
                tell application \"Terminal\" to activate
                delay 0.1
                tell application \"System Events\" to keystroke \"v\" using command down
                delay 0.05
                tell application \"System Events\" to keystroke return
            "
            echo "→ $addr: sent"
            ;;
    esac
}
```

### `read_from` - Read content from address

```bash
read_from() {
    local addr=$1
    local lines=${2:-30}
    IFS='.' read -r session type window pane <<< "$addr"

    case "$type" in
        tmux)
            local pane_id=$(tmux list-panes -t "$session:$window" -F '#{pane_title} #{pane_id}' | grep "^$pane " | awk '{print $2}')
            tmux capture-pane -t "$pane_id" -p -S -"$lines"
            ;;
        terminal)
            osascript -e 'tell application "Terminal" to get contents of selected tab of front window'
            ;;
    esac
}
```

### `kill_addr` - Kill pane, window, or session

```bash
kill_addr() {
    local addr=$1
    IFS='.' read -r session type window pane <<< "$addr"

    if [[ -n "$pane" ]]; then
        # Kill pane: uart.tmux.dv.tx
        local pane_id=$(tmux list-panes -t "$session:$window" -F '#{pane_title} #{pane_id}' 2>/dev/null | grep "^$pane " | awk '{print $2}')
        if [[ -n "$pane_id" ]]; then
            tmux kill-pane -t "$pane_id"
            echo "✓ Killed pane $addr"
        else
            echo "✗ Pane not found: $addr"
        fi
    elif [[ -n "$window" ]]; then
        # Kill window: uart.tmux.dv
        tmux kill-window -t "$session:$window" 2>/dev/null && echo "✓ Killed window $addr" || echo "✗ Window not found: $addr"
    else
        # Kill session: uart.tmux
        tmux kill-session -t "$session" 2>/dev/null && echo "✓ Killed session $session" || echo "✗ Session not found: $session"
    fi
}
```

### `attach` - Open terminal attached to tmux session

```bash
attach() {
    local session=$1
    osascript -e "tell application \"Terminal\" to do script \"tmux attach -t $session || tmux new -s $session\""
}
```

### Usage

```bash
# Run command at address (auto-creates session/window/pane + opens Terminal)
run "codex" "uart.tmux.design.tx"
run "claude" "uart.tmux.design.rx"
run "htop" "myapp.terminal.monitor"

# Send text/prompt to address
send "uart.tmux.design.tx" "fix the bug"

# Read output from address
read_from "uart.tmux.design.tx" 50

# Kill (pane/window/session based on address depth)
kill_addr "uart.tmux.design.tx"   # kill pane
kill_addr "uart.tmux.design"      # kill window
kill_addr "uart.tmux"             # kill session

# Attach terminal to session
attach "uart"
```
```

### `agents` - List all panes with status

```bash
agents() {
    echo "┌────────────────────────────────┬────────┬──────────┬──────────────┐"
    echo "│ Address                        │ Pane   │ Status   │ Last Line    │"
    echo "├────────────────────────────────┼────────┼──────────┼──────────────┤"

    tmux list-panes -a -F '#{session_name} #{window_name} #{pane_title} #{pane_id}' 2>/dev/null | while read session window pane pane_id; do
        local addr="$session.tmux.$window.$pane"
        local last=$(tmux capture-pane -t "$pane_id" -p -S -1 | tail -1 | cut -c1-12)
        local content=$(tmux capture-pane -t "$pane_id" -p -S -5)
        local state="busy"
        echo "$content" | grep -qE '^> $|^\$ $' && state="idle"
        echo "$content" | grep -qE '\[y/n\]|!' && state="waiting"
        printf "│ %-30s │ %-6s │ %-8s │ %-12s │\n" "$addr" "$pane_id" "$state" "$last"
    done

    echo "└────────────────────────────────┴────────┴──────────┴──────────────┘"
}
```

### Output

```
┌────────────────────────────────┬────────┬──────────┬──────────────┐
│ Address                        │ Pane   │ Status   │ Last Line    │
├────────────────────────────────┼────────┼──────────┼──────────────┤
│ uart.tmux.dv.tx                │ %1     │ idle     │ >            │
│ uart.tmux.dv.rx                │ %2     │ busy     │ Thinking...  │
└────────────────────────────────┴────────┴──────────┴──────────────┘
```

---

## Control Matrix

| From → To | Method | Focus Required |
|-----------|--------|----------------|
| **tmux → tmux** | `tmux send-keys` | No |
| **terminal → tmux** | `tmux send-keys` | No |
| **tmux → terminal** | AppleScript | Yes |
| **terminal → terminal** | AppleScript | Yes |

---

## Part 1: tmux Control (Focus-Free)

### Addressing by Name

```bash
# Using named targets
tmux send-keys -t "uart:dv.tx" -l "hello"    # session:window.pane
tmux send-keys -t "=uart:=dv" -l "hello"     # Exact match (prevents partial)

# List with names
tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_title} #{pane_id}"
```

### Core Commands

```bash
# List all panes
tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index} #{pane_id} #{pane_pid}"

# Send text literally (no key interpretation)
tmux send-keys -t <target> -l "your text"

# Send keys
tmux send-keys -t <target> Enter
tmux send-keys -t <target> Escape
tmux send-keys -t <target> C-c        # Ctrl+C
tmux send-keys -t <target> Tab

# Read pane content (last 100 lines)
tmux capture-pane -t <target> -p -S -100
```

### Target Syntax
```bash
<session>:<window>.<pane>    # "main:0.1"
%<pane_id>                   # "%5" (direct)
```

### Critical: Escape + Return for Claude Code
```bash
# Claude Code needs Escape THEN Return to submit
tmux send-keys -t %5 -l "prompt"
sleep 0.1
tmux send-keys -t %5 Escape
sleep 0.1
tmux send-keys -t %5 Enter
```

### Delays Are Essential
| After | Delay | Why |
|-------|-------|-----|
| Escape (single-line) | 100ms | Prevent `Esc+key` → `M-key` |
| **Escape (multi-line)** | **500ms** | Claude needs more time for multi-line buffer |
| Text before Enter | 50-100ms | Let buffer flush |
| After paste-buffer | 200ms | Let tmux buffer sync |
| Ctrl+C | 200ms | Allow interrupt to process |

**tmux.conf optimization:**
```bash
set-option -sg escape-time 10  # Reduce from 500ms default
```

### Agent Helper Functions

```bash
# Send multi-line text using tmux buffer (recommended)
send_multiline() {
    local pane=$1
    local text=$2
    local agent_type=${3:-"other"}  # claude, gemini, codex, other

    # Create temp file and load into tmux buffer
    local tmpfile=$(mktemp)
    echo -n "$text" > "$tmpfile"
    tmux load-buffer "$tmpfile"
    tmux paste-buffer -t "$pane"
    rm "$tmpfile"

    sleep 0.2  # Wait after paste

    # Submit based on agent type
    case "$agent_type" in
        claude)
            tmux send-keys -t "$pane" Escape
            sleep 0.5  # 500ms delay for multi-line
            tmux send-keys -t "$pane" Enter
            ;;
        gemini)
            tmux send-keys -t "$pane" Escape
            sleep 0.3
            tmux send-keys -t "$pane" Enter
            ;;
        *)
            tmux send-keys -t "$pane" Enter
            ;;
    esac
}

# Verify command was executed (check pane is working)
verify_sent() {
    local pane=$1
    sleep 2
    local content=$(tmux capture-pane -t "$pane" -p -S -5)
    if echo "$content" | grep -qiE "Working|Creating|writing|Thinking|running|⠋|⠙"; then
        echo "$pane: ✓ WORKING"
        return 0
    elif echo "$content" | grep -qE "bypass|context left|/model|\$ $|> $"; then
        echo "$pane: ⏳ IDLE (may need retry)"
        return 1
    else
        echo "$pane: ❓ CHECK"
        return 1
    fi
}

# Claude Code (single-line)
send_claude() {
    tmux send-keys -t "$1" -l "$2"
    sleep 0.1 && tmux send-keys -t "$1" Escape
    sleep 0.1 && tmux send-keys -t "$1" Enter
}

# Claude Code (multi-line) - use 500ms delay
send_claude_multi() {
    local pane=$1
    local text=$2
    local tmpfile=$(mktemp)
    echo -n "$text" > "$tmpfile"
    tmux load-buffer "$tmpfile"
    tmux paste-buffer -t "$pane"
    rm "$tmpfile"
    sleep 0.2
    tmux send-keys -t "$pane" Escape
    sleep 0.5  # Critical: 500ms for multi-line
    tmux send-keys -t "$pane" Enter
}

# Other agents (Codex, Gemini, OpenCode)
send_agent() {
    tmux send-keys -t "$1" -l "$2"
    sleep 0.05 && tmux send-keys -t "$1" Enter
}
```

### Wait-for Synchronization
```bash
# Wait for command completion
tmux send-keys -t %5 'command; tmux wait-for -S done' Enter
tmux wait-for done
```

---

## Part 2: AppleScript Control (Requires Focus)

Use when controlling Terminal.app/iTerm from outside tmux.

### List Windows
```bash
osascript -e 'tell application "Terminal" to get id of every window'
```

### Send Text (via Clipboard)
```bash
osascript <<'EOF'
set oldClip to the clipboard
set the clipboard to "your command here"
tell application "Terminal"
    activate
    set frontmost of window 1 to true
end tell
delay 0.1
tell application "System Events"
    keystroke "v" using command down
end tell
delay 0.1
set the clipboard to oldClip
EOF
```

### Send Keys
```bash
osascript <<'EOF'
tell application "Terminal" to activate
delay 0.1
tell application "System Events"
    tell process "Terminal"
        keystroke return
    end tell
end tell
EOF
```

### Send Escape + Return (for Claude in Terminal)
```bash
osascript <<'EOF'
tell application "Terminal" to activate
delay 0.1
tell application "System Events"
    tell process "Terminal"
        key code 53  -- Escape
        delay 0.1
        keystroke return
    end tell
end tell
EOF
```

### Read Content
```bash
osascript -e 'tell application "Terminal" to get contents of selected tab of window 1'
```

### Key Codes Reference
```
return=36, escape=53, tab=48, space=49, delete=51
up=126, down=125, left=123, right=124
```

---

## Part 3: Cross-Control Patterns

### From tmux to Terminal.app (outside tmux)
```bash
# AppleScript (switches focus)
tmux_to_terminal() {
    osascript -e "
        set the clipboard to \"$1\"
        tell application \"Terminal\" to activate
        delay 0.1
        tell application \"System Events\" to keystroke \"v\" using command down
        delay 0.05
        tell application \"System Events\" to keystroke return
    "
}
```

### From Terminal.app to tmux pane
```bash
# tmux send-keys (always works, no focus needed)
terminal_to_tmux() {
    tmux send-keys -t "$1" -l "$2"
    sleep 0.05
    tmux send-keys -t "$1" Enter
}
```

---

## Part 5: Monitoring & State Detection

### tmux: Capture Pane Content

```bash
# Last N lines (most common)
tmux capture-pane -t %5 -p -S -100

# Full scrollback history
tmux capture-pane -t %5 -p -S -

# Visible content only (no scrollback)
tmux capture-pane -t %5 -p

# With escape sequences (for color detection)
tmux capture-pane -t %5 -p -e -S -50

# Save to file
tmux capture-pane -t %5 -p -S -100 > /tmp/pane_output.txt
```

### tmux: Change Detection (MD5 Hash)

```bash
# Detect when output changes
watch_pane() {
    local target=$1
    local prev_hash=""

    while true; do
        content=$(tmux capture-pane -t "$target" -p -S -50)
        curr_hash=$(echo "$content" | md5)

        if [[ "$curr_hash" != "$prev_hash" ]]; then
            echo "Output changed at $(date)"
            prev_hash=$curr_hash
        fi
        sleep 0.5
    done
}
```

### tmux: Wait for Pattern

```bash
# Wait until specific pattern appears
wait_for_pattern() {
    local target=$1
    local pattern=$2
    local timeout=${3:-30}
    local start=$(date +%s)

    while true; do
        content=$(tmux capture-pane -t "$target" -p -S -20)
        if echo "$content" | grep -qE "$pattern"; then
            return 0
        fi

        elapsed=$(($(date +%s) - start))
        if [[ $elapsed -ge $timeout ]]; then
            return 1  # Timeout
        fi
        sleep 0.3
    done
}

# Usage: wait for prompt
wait_for_pattern %5 '(\$|>|#) $' 60
```

### tmux: Agent State Detection

```bash
detect_agent_state() {
    local target=$1
    local content=$(tmux capture-pane -t "$target" -p -S -10)
    local last_line=$(echo "$content" | tail -1)

    # Claude Code states
    if echo "$last_line" | grep -q '^>'; then
        echo "idle"
    elif echo "$content" | grep -q '!'; then
        echo "pending_approval"
    elif echo "$content" | grep -qE '(Thinking|Reading|Writing|Running)'; then
        echo "busy"
    else
        echo "unknown"
    fi
}
```

### Agent State Patterns

| Agent | Idle Pattern | Busy Pattern | Pending Approval |
|-------|--------------|--------------|------------------|
| **Claude Code** | `^> $` at end | Spinner/streaming | `!` in status |
| **Codex CLI** | `\$ $` prompt | Output streaming | `[y/n]` or `[Y/n]` |
| **Gemini CLI** | `> $` prompt | Response text | Confirmation prompt |
| **Aider** | `> $` or `>>>` | Diff output | `y/n` question |
| **OpenCode** | `> $` prompt | Streaming | Confirmation |

### tmux: Polling Loop with Callback

```bash
monitor_pane() {
    local target=$1
    local callback=$2
    local interval=${3:-1}

    while true; do
        content=$(tmux capture-pane -t "$target" -p -S -30)
        $callback "$content"
        sleep "$interval"
    done
}

# Example callback
on_content() {
    local content=$1
    if echo "$content" | grep -q "error"; then
        echo "Error detected!"
    fi
}

# Usage
monitor_pane %5 on_content 0.5
```

### AppleScript: Read Terminal Content

```bash
# Read Terminal.app content
osascript -e 'tell application "Terminal" to get contents of selected tab of window 1'

# Read specific window by ID
osascript -e 'tell application "Terminal" to get contents of selected tab of window id 1234'

# Get history (may be limited)
osascript -e 'tell application "Terminal" to get history of selected tab of window 1'
```

### Monitor Script

```bash
#!/bin/bash
# Universal pane monitor

monitor() {
    local target=$1
    local mode=${2:-tmux}  # tmux, applescript

    case $mode in
        tmux)
            tmux capture-pane -t "$target" -p -S -50
            ;;
        applescript)
            osascript -e "tell application \"Terminal\" to get contents of selected tab of window id $target"
            ;;
    esac
}

# Continuous monitoring with change detection
continuous_monitor() {
    local target=$1
    local mode=$2
    local prev=""

    while true; do
        curr=$(monitor "$target" "$mode")
        if [[ "$curr" != "$prev" ]]; then
            clear
            echo "=== $(date) ==="
            echo "$curr" | tail -20
            prev=$curr
        fi
        sleep 0.5
    done
}
```

### Idle Detection with Timeout

```bash
wait_for_idle() {
    local target=$1
    local timeout=${2:-120}
    local check_interval=${3:-1}
    local stable_count=0
    local stable_needed=3  # Need 3 consecutive idle checks
    local start=$(date +%s)

    while true; do
        state=$(detect_agent_state "$target")

        if [[ "$state" == "idle" ]]; then
            ((stable_count++))
            if [[ $stable_count -ge $stable_needed ]]; then
                return 0
            fi
        else
            stable_count=0
        fi

        elapsed=$(($(date +%s) - start))
        if [[ $elapsed -ge $timeout ]]; then
            return 1
        fi

        sleep "$check_interval"
    done
}
```

---

## Lessons Learned (2026-02)

### AppleScript Limitations

| Issue | Cause | Solution |
|-------|-------|----------|
| Tab creation unreliable | `keystroke "t"` goes to wrong window | Use separate Terminal windows |
| keystroke sends to wrong app | Terminal not properly focused | Use `tmux send-keys` instead |
| Custom title overwritten | Apps (Claude) change terminal title | Accept or disable in Terminal prefs |

### Best Practices

1. **One tmux window = One Terminal window** - Don't try to create tabs programmatically
2. **Use grouped sessions** - For independent window views (`uart` + `uart_dv`)
3. **Use `tmux send-keys`** - More reliable than AppleScript keystroke for text input
4. **AppleScript only for window management** - Creating/finding windows, not sending keystrokes
5. **Delays after Escape** - 100ms for single-line, **500ms for multi-line** (critical for Claude)
6. **Use `tmux load-buffer` + `paste-buffer`** - For multi-line text input
7. **Always verify after send** - Check pane status to confirm command executed
8. **Gemini sandbox** - Start Gemini from target directory to avoid path restrictions

### Multi-line Text Pattern (Recommended)

```bash
# Send multi-line prompt to agent
send_and_verify() {
    local pane=$1
    local text=$2
    local agent=$3  # claude, gemini, codex

    # 1. Check pane is ready before sending
    local before=$(tmux capture-pane -t "$pane" -p -S -3)

    # 2. Send via buffer (handles multi-line correctly)
    local tmpfile=$(mktemp)
    echo -n "$text" > "$tmpfile"
    tmux load-buffer "$tmpfile"
    tmux paste-buffer -t "$pane"
    rm "$tmpfile"

    # 3. Submit with appropriate delay
    sleep 0.2
    case "$agent" in
        claude)
            tmux send-keys -t "$pane" Escape
            sleep 0.5  # 500ms for Claude multi-line
            ;;
        gemini)
            tmux send-keys -t "$pane" Escape
            sleep 0.3
            ;;
    esac
    tmux send-keys -t "$pane" Enter

    # 4. Verify execution started
    sleep 2
    local after=$(tmux capture-pane -t "$pane" -p -S -3)
    if [[ "$before" != "$after" ]]; then
        echo "✓ $pane: Command sent"
    else
        echo "⚠ $pane: May need retry"
    fi
}
```

### tmux.conf Minimal Setup

```bash
# ~/.tmux.conf
set -sg escape-time 10      # Reduce escape delay (default 500ms)
set -g mouse on             # Enable mouse for pane selection
set -g base-index 1         # Start window numbering at 1
set -g set-titles on        # Allow title setting
set -g set-titles-string "#S.#W"  # Format: session.window
```

## Common Pitfalls

| Issue | Cause | Fix |
|-------|-------|-----|
| `M-i` instead of Esc then i | No delay | Add `sleep 0.1` after Escape |
| Wrong pane | Ambiguous target | Use exact `%N` pane ID |
| Text truncated | Special chars | Use `-l` flag |
| Focus stolen | Using AppleScript | Use tmux panes instead |
| Command not run | Missing Enter | Add `Enter` after text |
| Keystrokes to wrong window | AppleScript keystroke | Use `tmux send-keys` for tmux panes |
| Tab creation fails | AppleScript limitation | Use separate windows |
| **Multi-line not submitted** | Escape delay too short | Use **500ms** delay before Enter for Claude |
| Multi-line text garbled | Using send-keys -l | Use `load-buffer` + `paste-buffer` instead |
| Gemini can't write files | Sandbox restriction | Start Gemini from target directory |
| Command not executed | No verification | Always check pane after send |

---

## Quick Reference Card

```bash
# === SEND ===
tmux send-keys -t %5 -l "text"              # Send text literally
tmux send-keys -t %5 Enter Escape C-c       # Send keys
osascript -e 'tell app "Terminal" to activate'  # Focus Terminal

# === READ / MONITOR ===
tmux capture-pane -t %5 -p -S -100          # Last 100 lines
tmux capture-pane -t %5 -p -S -             # Full history
tmux capture-pane -t %5 -p                  # Visible only
osascript -e 'tell app "Terminal" to get contents of selected tab of window 1'

# === LIST ===
tmux list-panes -a -F "#{pane_id} #{pane_title}"
osascript -e 'tell app "Terminal" to get id of every window'

# === CHANGE DETECTION ===
content=$(tmux capture-pane -t %5 -p -S -50)
hash=$(echo "$content" | md5)               # Compare hashes

# === STATE DETECTION ===
# Idle: ends with '> $' or '$ $'
# Busy: contains spinner or streaming output
# Approval: contains '!' or '[y/n]'

# === KEY CODES ===
# tmux: C-=Ctrl, M-=Alt, Enter, Escape, Tab, Space, BSpace
# AppleScript: return=36, escape=53, tab=48, space=49, delete=51
```

---

## Sources

- [tmux send-keys patterns](https://minimul.com/increased-developer-productivity-with-tmux-part-5.html)
- [Scripting tmux](https://www.arp242.net/tmux.html)
- [Control sequences gist](https://gist.github.com/stephancasas/1c82b66be1ea664c2a8f18019a436938)
- [Agent Conductor](https://github.com/gaurav-yadav/agent-conductor)
- [Claude Squad](https://github.com/smtg-ai/claude-squad)
- [TmuxCC](https://github.com/nyanko3141592/tmuxcc)
