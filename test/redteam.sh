#!/usr/bin/env bash
# Adversarial test suite for claude-profiles.sh.
#
#   ./test/redteam.sh          run under bash and zsh
#   ./test/redteam.sh bash     run under one shell only
#
# Everything happens inside a throwaway sandbox with a fake HOME and a stub
# `claude` binary. Canary files assert that nothing outside a profile
# directory is ever touched. Exits non-zero if any check fails.

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)/claude-profiles.sh"
STATUS_BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/profile-status.sh"
FAILURES=0

pass() { printf '  ok    %s\n' "$1"; }
fail() {
    printf '  FAIL  %s\n' "$1"
    FAILURES=$((FAILURES + 1))
}

# assert_contains <description> <needle> <haystack>
assert_contains() {
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1 (expected to find: $2)" ;;
    esac
}

# assert_not_contains <description> <needle> <haystack>
assert_not_contains() {
    case "$3" in
        *"$2"*) fail "$1 (should NOT contain: $2)" ;;
        *) pass "$1" ;;
    esac
}

run_suite() {
    local sh="$1"
    if ! command -v "$sh" >/dev/null 2>&1; then
        printf '\n== %s not installed, skipping ==\n' "$sh"
        return 0
    fi

    printf '\n===== shell: %s =====\n' "$sh"

    local SB
    SB=$(mktemp -d "${TMPDIR:-/tmp}/claude-profiles-test.XXXXXX") || return 1
    mkdir -p "$SB/home/.claude/skills" "$SB/bin" "$SB/OUTSIDE"

    # Canaries: these must survive every hostile input below.
    echo "REAL_SETTINGS" > "$SB/home/.claude/settings.json"
    echo "REAL_SKILL" > "$SB/home/.claude/skills/keep.txt"
    echo "REAL_TOPLEVEL" > "$SB/home/CANARY_HOME.txt"
    echo "OUTSIDE_CANARY" > "$SB/OUTSIDE/canary.txt"
    echo '{"oauthAccount":{"emailAddress":"default@example.com"}}' > "$SB/home/.claude.json"

    # Stub CLI: reports the config dir and profile it was handed. Also answers
    # --help, because the wrapper consults it before rejecting an unknown
    # -<name> — and advertises a hypothetical single-dash multi-char flag so
    # the "don't break a future flag" path is exercised.
    cat > "$SB/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "STUB|CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}|args:$*|profile=${CLAUDE_PROFILE:-<unset>}"
if [ "${1:-}" = "--help" ]; then
    printf 'Options:\n  -c, --continue\n  -p, --print\n  -fast, --fast-mode  hypothetical\n'
fi
STUB
    chmod +x "$SB/bin/claude"

    # run <shell code> -> stdout+stderr
    run() {
        HOME="$SB/home" PATH="$SB/bin:$PATH" \
            CLAUDE_PROFILES_DIR="$SB/home/.claude-profiles" \
            "$sh" -c ". '$SRC'
$1" 2>&1
    }

    local out

    printf '\n-- baseline --\n'
    out=$(run "claude-profile ls")
    assert_contains "ls shows default account" "default@example.com" "$out"

    out=$(run "claude-profile new work </dev/null")
    assert_contains "new creates profile" 'Created profile "work"' "$out"
    assert_contains "new shares settings.json" "settings.json" "$out"
    assert_contains "new shares skills" "skills" "$out"

    out=$(run "ls -1 \"\$CLAUDE_PROFILES_DIR/work\"")
    assert_contains "settings.json symlinked into profile" "settings.json" "$out"
    assert_contains "skills symlinked into profile" "skills" "$out"

    printf '\n-- isolation --\n'
    out=$(run "claude -work chat")
    assert_contains "profile sets CLAUDE_CONFIG_DIR" "/.claude-profiles/work|args:chat" "$out"

    printf '\n-- real flags must pass through --\n'
    for flag in -c -d -r -v -w -n --version --help; do
        out=$(run "claude $flag")
        assert_contains "flag $flag untouched" "CLAUDE_CONFIG_DIR=<unset>|args:$flag" "$out"
    done
    out=$(run "claude -p 'hi'")
    assert_contains "flag -p untouched" "CLAUDE_CONFIG_DIR=<unset>|args:-p hi" "$out"

    printf '\n-- path traversal --\n'
    for bad in ".." "../.." "../../OUTSIDE" "/" "." "/tmp/evil" "../evil" "-dashy"; do
        out=$(run "claude-profile rm '$bad' </dev/null")
        assert_contains "rm rejects '$bad'" "invalid profile name" "$out"
        out=$(run "claude-profile new '$bad' </dev/null")
        assert_contains "new rejects '$bad'" "invalid profile name" "$out"
    done

    out=$(run "claude -../../etc")
    assert_contains "wrapper ignores traversal arg" "CLAUDE_CONFIG_DIR=<unset>" "$out"

    printf '\n-- command injection --\n'
    out=$(run "claude-profile new 'a; touch \"$SB/PWNED\"' </dev/null")
    assert_contains "new rejects injected name" "invalid profile name" "$out"
    out=$(run "claude-profile new 'a\$(touch \"$SB/PWNED2\")' </dev/null")
    assert_contains "new rejects substitution name" "invalid profile name" "$out"
    out=$(run "claude-profile rm 'a; rm -rf \"$SB/OUTSIDE\"' </dev/null")
    assert_contains "rm rejects injected name" "invalid profile name" "$out"

    printf '\n-- reserved names --\n'
    for short in p c r d; do
        out=$(run "claude-profile new $short </dev/null")
        assert_contains "new rejects single-char '$short'" "too short to be safe" "$out"
    done

    printf '\n-- deletion --\n'
    out=$(run "printf 'y\n' | claude-profile rm work")
    assert_contains "wrong confirmation aborts" "Aborted" "$out"
    out=$(run "ls -1 \"\$CLAUDE_PROFILES_DIR\"")
    assert_contains "profile survives aborted delete" "work" "$out"

    out=$(run "printf 'work\n' | claude-profile rm work")
    assert_contains "correct confirmation deletes" 'Deleted "work"' "$out"
    out=$(run "ls -1 \"\$CLAUDE_PROFILES_DIR\"")
    assert_not_contains "profile gone after delete" "work" "$out"

    printf '\n-- canaries (shared config must survive symlink deletion) --\n'
    assert_contains "shared settings.json intact" "REAL_SETTINGS" "$(cat "$SB/home/.claude/settings.json" 2>&1)"
    assert_contains "shared skill intact" "REAL_SKILL" "$(cat "$SB/home/.claude/skills/keep.txt" 2>&1)"
    assert_contains "home canary intact" "REAL_TOPLEVEL" "$(cat "$SB/home/CANARY_HOME.txt" 2>&1)"
    assert_contains "outside canary intact" "OUTSIDE_CANARY" "$(cat "$SB/OUTSIDE/canary.txt" 2>&1)"
    if [ -e "$SB/PWNED" ] || [ -e "$SB/PWNED2" ]; then
        fail "injection marker was created"
    else
        pass "no injection markers created"
    fi

    printf '\n-- malformed input --\n'
    mkdir -p "$SB/home/.claude-profiles/bad" "$SB/home/.claude-profiles/empty"
    printf 'not json at all {{{' > "$SB/home/.claude-profiles/bad/.claude.json"
    : > "$SB/home/.claude-profiles/empty/.claude.json"
    out=$(run "claude-profile ls")
    assert_contains "malformed json handled" "-bad" "$out"
    assert_contains "empty json handled" "not logged in" "$out"

    printf '\n-- account parsing without python3 or node --\n'
    mkdir -p "$SB/home/.claude-profiles/np"
    echo '{"oauthAccount":{"emailAddress":"fallback@example.com"}}' \
        > "$SB/home/.claude-profiles/np/.claude.json"
    # Build a PATH containing the usual utilities but deliberately NO python3
    # and NO node, so the grep/sed fallback is the only way to read the email.
    mkdir -p "$SB/minbin"
    for tool in grep sed head cat find sort basename ls tr rm mkdir chmod ln mktemp; do
        src=$(command -v "$tool" 2>/dev/null) && ln -sf "$src" "$SB/minbin/$tool"
    done
    # Absolute path: the PATH assignment applies to this command's own
    # lookup, so "$sh" alone would not be found.
    local sh_abs
    sh_abs=$(command -v "$sh")
    out=$(HOME="$SB/home" PATH="$SB/minbin:$SB/bin" \
        CLAUDE_PROFILES_DIR="$SB/home/.claude-profiles" \
        "$sh_abs" -c ". '$SRC'; claude-profile ls" 2>&1)
    assert_not_contains "python3 really is absent" "python3-was-found" \
        "$(PATH="$SB/minbin:$SB/bin" command -v python3 >/dev/null 2>&1 && echo python3-was-found)"
    assert_contains "grep fallback finds email" "fallback@example.com" "$out"

    # The deletion section above removed "work"; recreate it for what follows.
    run "claude-profile new work </dev/null" >/dev/null 2>&1

    printf '\n-- no silent fallback to the default profile --\n'
    # The whole point: a mistyped or missing profile must never quietly run
    # the default account, because that bills the wrong client.
    out=$(run "claude -nosuchprofile chat; echo exit=\$?")
    assert_contains "unknown profile exits 2" "exit=2" "$out"
    assert_not_contains "unknown profile never reaches the CLI" "STUB|" "$out"
    assert_contains "unknown profile explains itself" "Refusing to fall back" "$out"

    # ...but a genuine flag we have never heard of must still work, so a future
    # Claude Code release cannot be broken by this check.
    out=$(run "claude -fast chat")
    assert_contains "unknown-but-real flag passes through" "args:-fast chat" "$out"

    printf '\n-- profile is announced --\n'
    out=$(run "claude -work chat")
    assert_contains "banner names the profile" "claude-profiles: work" "$out"
    assert_contains "CLAUDE_PROFILE exported to the child" "profile=work" "$out"
    out=$(run "CLAUDE_PROFILE_QUIET=1 claude -work chat")
    assert_not_contains "banner suppressible" "claude-profiles: work" "$out"
    out=$(run "claude -work chat 2>/dev/null")
    assert_not_contains "banner goes to stderr, not stdout" "claude-profiles: work" "$out"

    printf '\n-- exec: the scripted path --\n'
    out=$(run "claude-profile exec work -- claude -p hi")
    assert_contains "exec sets the config dir" "/.claude-profiles/work|args:-p hi" "$out"
    out=$(run "claude-profile exec nope -- claude; echo exit=\$?")
    assert_contains "exec rejects unknown profile" "exit=2" "$out"

    printf '\n-- status line --\n'
    mkdir -p "$SB/home/.claude-profiles/work/projects/-slug"
    echo '{"oauthAccount":{"emailAddress":"work@example.com"}}' \
        > "$SB/home/.claude-profiles/work/.claude.json"
    sl() {
        printf '{"transcript_path":"%s","cost":{"total_cost_usd":1.5},"rate_limits":{"five_hour":{"used_percentage":34},"seven_day":{"used_percentage":88}}}' "$1" |
            HOME="$SB/home" CLAUDE_CONFIG_DIR="${2:-}" sh "$STATUS_BIN" 2>&1
    }
    out=$(sl "$SB/home/.claude-profiles/work/projects/-slug/x.jsonl" "$SB/home/.claude-profiles/work")
    assert_contains "status line names the profile" "work" "$out"
    assert_contains "status line shows the account" "work@example.com" "$out"
    assert_contains "status line uses the 5h window, not the 7d one" "34%" "$out"
    assert_not_contains "status line does not show the 7d window" "88%" "$out"

    mkdir -p "$SB/home/.claude/projects/-slug"
    out=$(sl "$SB/home/.claude/projects/-slug/x.jsonl" "")
    assert_contains "unprofiled session reads as default" "default" "$out"

    # Subagent transcripts nest deeper than a session's own:
    #   <config>/projects/<slug>/<uuid>/subagents/agent-<id>.jsonl
    # Counting directories back up from the file resolves to the wrong config
    # dir at that depth, which mislabels the profile and can fire a false
    # mismatch — so depth must not matter.
    out=$(sl "$SB/home/.claude-profiles/work/projects/-slug/u/subagents/agent-1.jsonl" \
        "$SB/home/.claude-profiles/work")
    assert_contains "nested subagent transcript still names the profile" "work" "$out"
    assert_not_contains "nested transcript does not false-alarm" "MISMATCH" "$out"
    out=$(sl "$SB/home/.claude/projects/-slug/u/subagents/agent-1.jsonl" "")
    assert_contains "nested transcript in default profile reads as default" "default" "$out"

    # The tripwire: launcher says one profile, Claude Code is writing to another.
    out=$(sl "$SB/home/.claude/projects/-slug/x.jsonl" "$SB/home/.claude-profiles/work")
    assert_contains "mismatch is loud" "PROFILE MISMATCH" "$out"
    assert_contains "mismatch names who is really billed" "billing=default" "$out"

    out=$(printf '' | HOME="$SB/home" sh "$STATUS_BIN" 2>&1)
    assert_contains "status line survives empty stdin" "default" "$out"
    out=$(printf 'not json' | HOME="$SB/home" sh "$STATUS_BIN" 2>&1)
    assert_not_contains "status line survives junk stdin" "error" "$out"

    printf '\n-- audit --\n'
    out=$(run "claude-profile audit; echo exit=\$?")
    assert_contains "clean audit exits 0" "exit=0" "$out"
    printf 'key sk-ant-api03-AAAAAAAAAAAAAAAAAAAA\n' > "$SB/home/.claude/skills/leak.txt"
    out=$(run "claude-profile audit; echo exit=\$?")
    assert_contains "audit finds a planted credential" "hard-coded credential pattern" "$out"
    assert_contains "dirty audit exits 1" "exit=1" "$out"
    assert_not_contains "audit never prints the secret itself" "sk-ant-api03-AAAA" "$out"
    rm -f "$SB/home/.claude/skills/leak.txt"

    printf '\n-- doctor and repair survive an un-shared settings file --\n'
    # Exactly what an atomic temp-file-plus-rename settings write leaves
    # behind: the symlink is gone and the profile silently stopped sharing.
    rm -f "$SB/home/.claude-profiles/work/settings.json"
    echo '{"diverged":true}' > "$SB/home/.claude-profiles/work/settings.json"
    out=$(run "claude-profile doctor; echo exit=\$?")
    assert_contains "doctor spots the un-shared file" "UNSHARED settings.json" "$out"
    assert_contains "doctor exits non-zero on problems" "exit=1" "$out"

    out=$(run "claude-profile repair --all")
    assert_contains "repair relinks it" "relinked settings.json" "$out"
    out=$(run "test -L \"\$CLAUDE_PROFILES_DIR/work/settings.json\" && echo IS_LINK")
    assert_contains "settings.json is a symlink again" "IS_LINK" "$out"
    out=$(run "cat \"\$CLAUDE_PROFILES_DIR/work\"/settings.json.unshared-*")
    assert_contains "repair keeps the diverged copy" "diverged" "$out"

    out=$(run "claude-profile repair --all")
    assert_contains "repair is idempotent" "already correct" "$out"
    out=$(run "ls \"\$CLAUDE_PROFILES_DIR/work\" | grep -c unshared")
    assert_contains "repair did not pile up backups" "1" "$out"

    printf '\n-- bin/ is not a profile --\n'
    mkdir -p "$SB/home/.claude-profiles/bin"
    out=$(run "claude-profile ls")
    assert_not_contains "ls does not list bin as a profile" "-bin" "$out"
    out=$(run "claude-profile new bin </dev/null; echo exit=\$?")
    assert_contains "cannot create a profile named bin" "exit=1" "$out"

    printf '\n-- usage --\n'
    out=$(run "claude-profile bogus; echo exit=\$?")
    assert_contains "unknown command exits non-zero" "exit=1" "$out"
    out=$(run "claude-profile help")
    assert_contains "help prints usage" "claude-profile new" "$out"

    rm -rf "$SB"
}

if [ $# -gt 0 ]; then
    run_suite "$1"
else
    run_suite bash
    run_suite zsh
fi

printf '\n=====================\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'All checks passed.\n'
    exit 0
else
    printf '%d check(s) FAILED.\n' "$FAILURES"
    exit 1
fi
