#!/usr/bin/env bash
set -euo pipefail

export PATH="/Users/qlss/.claude/skills/terminal-orchestrator:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"

usage() {
    cat <<'EOF'
Usage: claude_send_checked.sh [--agent claude|gemini] <pane_id> <message...>

Sends a prompt to a Claude/Gemini tmux pane with the correct submit sequence:
- paste prompt
- Escape
- wait for UI to exit composer mode
- Enter
- verify the pane changed or the agent entered a busy state
- retry one bare Enter if the first submit was swallowed
EOF
}

agent="claude"
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --agent)
            agent="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ $# -ge 2 ]] || {
    usage >&2
    exit 2
}

pane="$1"
shift
msg="$*"

delay_after_escape="0.5"
if [[ "$agent" == "gemini" ]]; then
    delay_after_escape="0.3"
fi

capture() {
    tmux capture-pane -p -J -S -120 -t "$pane" 2>/dev/null || return 1
}

state() {
    tmi state "$pane" 2>/dev/null || true
}

is_busy() {
    local current_state="$1"
    local current_text="$2"
    if [[ "$agent" == "claude" ]] && [[ "$current_state" == *"app=claude busy=true"* ]]; then
        return 0
    fi
    if [[ "$agent" == "gemini" ]] && [[ "$current_state" == *"app=gemini busy=true"* ]]; then
        return 0
    fi
    echo "$current_text" | tail -20 | grep -qE '(● |Bootstrapping|Running [0-9]+ bash command|Running|Thinking|Searching|Reading|Writing|Waiting for background terminal|Analyzing|Generating)'
}

send_submit() {
    tmi send "$pane" --instant "$msg" >/dev/null
    sleep 0.05
    tmux send-keys -t "$pane" Escape
    sleep "$delay_after_escape"
    tmux send-keys -t "$pane" Enter
}

before="$(capture || true)"
send_submit
sleep 0.9
after="$(capture || true)"
after_state="$(state)"

if is_busy "$after_state" "$after" || [[ "$after" != "$before" ]]; then
    echo "status=submitted"
    printf '%s\n' "$after" | tail -n 12
    exit 0
fi

tmux send-keys -t "$pane" Enter
sleep 0.9
after_retry="$(capture || true)"
after_retry_state="$(state)"

if is_busy "$after_retry_state" "$after_retry" || [[ "$after_retry" != "$before" ]]; then
    echo "status=submitted_after_retry"
    printf '%s\n' "$after_retry" | tail -n 12
    exit 0
fi

echo "status=not_submitted" >&2
printf '%s\n' "$after_retry" | tail -n 20 >&2
exit 1
