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
- if Codex cold-start swallowed the first submit, send extra bare Enter retries
- if Codex queued the message instead of submitting it, send Escape to
  interrupt and submit immediately
- if the prompt is still sitting in the composer, keep nudging it until it
  enters a real working state or clearly fails

Exit codes:
- 0: submitted and pane entered working state
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

is_interrupted() {
    grep -Eq 'Conversation interrupted - tell the model what to do differently' <<<"$1"
}

has_draft_prompt() {
    local tail_window="$1"
    grep -Eq '^[[:space:]]*› ' <<<"$tail_window" &&
        grep -Eq 'gpt-[0-9]' <<<"$tail_window" &&
        ! is_working "$tail_window" &&
        ! is_queued "$tail_window" &&
        ! is_interrupted "$tail_window"
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

tail_window() {
    printf '%s\n' "$1" | tail -n 30
}

content_before="$(capture || true)"
current="$content_before"
prompt_retries=0
interrupt_retries=0

send_prompt

for _attempt in 1 2 3 4 5 6; do
    wait_short 0.5
    current="$(capture || true)"
    current_tail="$(tail_window "$current")"

    if is_queued "$current_tail"; then
        if (( interrupt_retries < 2 )); then
            send_interrupt_submit
            interrupt_retries=$((interrupt_retries + 1))
            continue
        fi
        echo "status=queued"
        echo "$current_tail"
        exit 1
    fi

    if is_working "$current_tail"; then
        echo "status=submitted"
        echo "$current_tail" | tail -n 12
        exit 0
    fi

    if is_interrupted "$current_tail"; then
        echo "status=interrupted"
        echo "$current_tail" | tail -n 20
        exit 1
    fi

    if [[ "$current" == "$content_before" ]] || has_draft_prompt "$current_tail"; then
        if (( prompt_retries < 3 )); then
            send_retry_enter
            prompt_retries=$((prompt_retries + 1))
            continue
        fi
    fi
done

final_tail="$(tail_window "$current")"
if is_queued "$final_tail"; then
    echo "status=queued"
    echo "$final_tail"
    exit 1
fi

if has_draft_prompt "$final_tail" || [[ "$current" == "$content_before" ]]; then
    echo "status=not_submitted"
    echo "$final_tail"
    exit 1
fi

echo "status=submitted"
echo "$final_tail" | tail -n 12
exit 0
