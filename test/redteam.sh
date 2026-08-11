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

    # Stub CLI: reports the config dir it was handed.
    cat > "$SB/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "STUB|CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}|args:$*"
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
