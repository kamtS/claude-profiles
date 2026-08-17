#!/usr/bin/env sh
# profile-status.sh — Claude Code statusLine renderer for claude-profiles.
#
# Prints which profile the CURRENT session is really running as, so a launcher
# that silently fell back to the default profile cannot go unnoticed.
#
# Wire it up once, in the SHARED ~/.claude/settings.json:
#
#     { "statusLine": { "type": "command",
#                       "command": "~/.claude-profiles/bin/profile-status.sh" } }
#
# One shared entry is correct for every profile. Claude Code runs the command
# per session with that session's own CLAUDE_CONFIG_DIR in the environment and
# hands it that session's transcript_path on stdin, so a single command string
# resolves differently in each session. Verified against Claude Code v2.1.223.
#
# Why transcript_path rather than $CLAUDE_CONFIG_DIR alone: the env var records
# what the launcher INTENDED. transcript_path records where Claude Code is
# actually writing. If a future release changed how CLAUDE_CONFIG_DIR is
# honoured, the env var would keep naming a client while the session billed
# someone else — a confident, wrong label, which is worse than no label. So the
# name comes from transcript_path, the env var is cross-checked against it, and
# a disagreement renders an alarm instead of a name.
#
# Pure POSIX shell on purpose: this runs on every status line render, so it
# avoids paying interpreter startup, and it works on machines with no python3
# or node (the same constraint the rest of claude-profiles honours).
#
# Licensed under the MIT License.

# No `set -e`: a status line must never break the session. Every step below is
# best-effort and degrades to a plainer line rather than failing.

_cp_in=$(cat 2>/dev/null)

# --- locate the session's real config dir ------------------------------------

# transcript_path is <config-dir>/projects/<slug>/<uuid>.jsonl — but not
# always: subagent transcripts nest deeper, as
# <config-dir>/projects/<slug>/<uuid>/subagents/agent-<id>.jsonl. So strip
# from the /projects/ segment rather than counting directories back up, which
# would silently resolve to the wrong directory at any other depth and could
# fire a false PROFILE MISMATCH. A tripwire that cries wolf is worse than none.
#
# `%` not `%%`: remove the SHORTEST matching suffix, i.e. split on the LAST
# /projects/, so a config dir that itself lives under a "projects" directory
# still resolves correctly.
_cp_tp=$(printf '%s' "$_cp_in" |
    sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1)

_cp_actual=""
case "$_cp_tp" in
    */projects/*) _cp_actual="${_cp_tp%/projects/*}" ;;
esac

# Fall back to the env var only when the transcript path is unusable (e.g. the
# very first render of a brand new session).
[ -n "$_cp_actual" ] || _cp_actual="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Normalise so a symlinked or trailing-slash path still compares equal.
_cp_norm() {
    [ -n "$1" ] || return 0
    if [ -d "$1" ]; then
        (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "${1%/}"
    else
        printf '%s' "${1%/}"
    fi
}

_cp_actual_n=$(_cp_norm "$_cp_actual")
_cp_home_n=$(_cp_norm "$HOME/.claude")

if [ "$_cp_actual_n" = "$_cp_home_n" ]; then
    _cp_name="default"
else
    _cp_name=$(basename "$_cp_actual_n")
fi

# --- the tripwire: intent vs reality -----------------------------------------

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    _cp_env_n=$(_cp_norm "$CLAUDE_CONFIG_DIR")
    if [ -n "$_cp_env_n" ] && [ "$_cp_env_n" != "$_cp_actual_n" ]; then
        # The launcher asked for one profile and Claude Code is using another.
        # Say so loudly and name the one that is actually being billed.
        printf '\033[1;31m⚠ PROFILE MISMATCH\033[0m launcher=%s \033[1mbilling=%s\033[0m\n' \
            "$(basename "$_cp_env_n")" "$_cp_name"
        exit 0
    fi
fi

# --- decoration ---------------------------------------------------------------

# Account email. When CLAUDE_CONFIG_DIR is set, Claude Code keeps .claude.json
# inside the config dir; the default profile keeps it at ~/.claude.json.
_cp_json="$_cp_actual_n/.claude.json"
[ -f "$_cp_json" ] || _cp_json="$HOME/.claude.json"
_cp_email=""
if [ -f "$_cp_json" ]; then
    _cp_email=$(grep -o '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' "$_cp_json" 2>/dev/null |
        head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
fi

# Spend so far this session. Unique key, safe to match directly.
_cp_cost=$(printf '%s' "$_cp_in" |
    sed -n 's/.*"total_cost_usd"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -n 1)

# Five-hour window usage. Present only for subscription accounts, and only
# after the first API response. Scoped to the five_hour object so it cannot
# pick up the seven_day figure by accident.
_cp_rl=$(printf '%s' "$_cp_in" |
    sed -n 's/.*"five_hour"[[:space:]]*:[[:space:]]*{[^}]*"used_percentage"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' |
    head -n 1)

_cp_line="⬢ $_cp_name"
[ -n "$_cp_email" ] && _cp_line="$_cp_line · $_cp_email"
case "$_cp_cost" in
    "" | 0 | 0.0 | 0.00) ;;
    *) _cp_line=$(printf '%s · $%.2f' "$_cp_line" "$_cp_cost" 2>/dev/null || printf '%s' "$_cp_line") ;;
esac
[ -n "$_cp_rl" ] && _cp_line=$(printf '%s · %.0f%%/5h' "$_cp_line" "$_cp_rl" 2>/dev/null || printf '%s' "$_cp_line")

# Dim, so it reads as chrome rather than content — except "default", which is
# brightened: an unlabelled session while you expected a client is the signal.
if [ "$_cp_name" = "default" ]; then
    printf '\033[33m%s\033[0m\n' "$_cp_line"
else
    printf '\033[2m%s\033[0m\n' "$_cp_line"
fi
