#!/bin/bash
set -euo pipefail

export PATH="/Users/qlss/.claude/skills/terminal-orchestrator:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"

usage() {
    cat <<'EOF'
Usage: codex_send_checked.sh <pane_id> <message...>

Sends a prompt to a Codex tmux pane and verifies it was actually submitted.
Default behavior:
- send prompt + Enter
- require real post-submit activity, not just prompt echo
- if Codex cold-start swallowed the first submit, send one extra bare Enter
- if Codex queued the message instead of submitting it, send Escape to
  interrupt and submit immediately

Exit codes:
- 0: submitted and pane entered working/changed state
- 1: prompt still appears queued or unsubmitted after retries
- 2: bad usage
EOF
}

[[ $# -ge 2 ]] || { usage >&2; exit 2; }

pane="$1"
shift
msg="$*"

tmi_cmd() {
    tmi "$@"
}

capture() {
    tmux capture-pane -p -t "$pane" 2>/dev/null || return 1
}

is_working() {
    grep -Eq 'Working \(|esc to interrupt' <<<"$1"
}

is_queued() {
    grep -Eq 'tab to queue message|Messages to be submitted after next tool call' <<<"$1"
}

send_prompt() {
    tmi_cmd send "$pane" --instant "$msg" >/dev/null
    sleep 0.05
    tmi_cmd send "$pane" --instant '\n' >/dev/null
}

send_retry_enter() {
    tmi_cmd send "$pane" --instant '\n' >/dev/null
}

send_interrupt_submit() {
    tmi_cmd send "$pane" --instant '\e' >/dev/null
}

wait_short() {
    sleep "${1:-0.4}"
}

capture_after_settle() {
    local first second
    first="$(capture || true)"
    wait_short 0.9
    second="$(capture || true)"
    printf '%s\n__CODEX_SEND_CHECKED_SPLIT__\n%s' "$first" "$second"
}

content_before="$(capture || true)"
send_prompt
wait_short 0.4
combined="$(capture_after_settle)"
content="${combined%%$'\n'__CODEX_SEND_CHECKED_SPLIT__*$'\n'*}"
content_after_wait="${combined#*$'\n'__CODEX_SEND_CHECKED_SPLIT__*$'\n'}"

# Codex cold-start case: prompt echoed but no real follow-up activity yet.
if ! is_working "$content_after_wait" && ! is_queued "$content_after_wait" && [[ "$content_after_wait" == "$content" ]]; then
    send_retry_enter
    wait_short 0.5
    combined="$(capture_after_settle)"
    content="${combined%%$'\n'__CODEX_SEND_CHECKED_SPLIT__*$'\n'*}"
    content_after_wait="${combined#*$'\n'__CODEX_SEND_CHECKED_SPLIT__*$'\n'}"
fi

# Queued-message case: force immediate submission so nothing is left hanging.
if is_queued "$content_after_wait"; then
    send_interrupt_submit
    wait_short 0.6
    combined="$(capture_after_settle)"
    content="${combined%%$'\n'__CODEX_SEND_CHECKED_SPLIT__*$'\n'*}"
    content_after_wait="${combined#*$'\n'__CODEX_SEND_CHECKED_SPLIT__*$'\n'}"
fi

if is_queued "$content_after_wait"; then
    echo "status=queued"
    echo "$content_after_wait" | tail -n 20
    exit 1
fi

if is_working "$content_after_wait" || [[ "$content_after_wait" != "$content" ]]; then
    echo "status=submitted"
    echo "$content_after_wait" | tail -n 12
    exit 0
fi

echo "status=not_submitted"
echo "$content_after_wait" | tail -n 20
exit 1
