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

    # Stub Codex: reports the home it was handed, and advertises its own
    # single-dash flags — including -p, which Codex uses for its *config*
    # profiles and which must therefore still reach it untouched.
    cat > "$SB/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "STUB|CODEX_HOME=${CODEX_HOME:-<unset>}|args:$*|profile=${CLAUDE_PROFILE:-<unset>}"
if [ "${1:-}" = "--help" ]; then
    printf 'Options:\n  -m, --model\n  -p, --profile\n  -codexonly, --codex-only  hypothetical\n'
fi
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then
    echo "Not logged in"
    exit 1
fi
STUB
    chmod +x "$SB/bin/codex"

    # Codex-side shared config, and its own canaries.
    mkdir -p "$SB/home/.codex/skills"
    echo "REAL_AGENTS" > "$SB/home/.codex/AGENTS.md"
    echo "REAL_CODEX_SKILL" > "$SB/home/.codex/skills/keep.txt"
    # Present precisely so the suite can prove it is NOT shared: config.toml
    # is where Codex keeps env_key and MCP server definitions.
    printf 'env_key = "OPENAI_API_KEY"\n' > "$SB/home/.codex/config.toml"

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
    # type -P forces a PATH search. `command -v` would answer from bash's
    # command hash instead, reporting a python3 that this PATH cannot reach
    # as soon as anything earlier in this script has run one.
    assert_not_contains "python3 really is absent" "python3-was-found" \
        "$(PATH="$SB/minbin:$SB/bin" type -P python3 >/dev/null 2>&1 && echo python3-was-found)"
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

    printf '\n-- doctor spots stale post-upgrade Claude sessions --\n'
    cat > "$SB/bin/id" <<'STUB'
#!/usr/bin/env bash
printf '501\n'
STUB
    cat > "$SB/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "-u 501 -x claude" ] || exit 0
printf '4242\n4343\n'
STUB
    cat > "$SB/bin/lsof" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *'-p 4242'*)
        printf 'p4242\nftxt\nn/removed path/claude-code/2.1.228.upgrading/claude\n'
        ;;
    *'-p 4343'*)
        printf 'p4343\nftxt\nn%s\n' "$CLAUDE_TEST_EXE"
        ;;
esac
STUB
    chmod +x "$SB/bin/id" "$SB/bin/pgrep" "$SB/bin/lsof"
    out=$(CLAUDE_TEST_EXE="$SB/bin/claude" run "claude-profile doctor; echo exit=\$?")
    assert_contains "doctor reports the stale process" "pid 4242" "$out"
    assert_contains "doctor explains the removed executable" \
        "/removed path/claude-code/2.1.228.upgrading/claude" "$out"
    assert_contains "doctor counts only removed executables" "WARN 1 session" "$out"
    assert_not_contains "doctor ignores a healthy executable" "pid 4343" "$out"
    assert_contains "doctor recommends a graceful exit" "exit those sessions normally" "$out"
    assert_contains "stale process makes doctor non-zero" "exit=1" "$out"
    rm -f "$SB/bin/id" "$SB/bin/pgrep" "$SB/bin/lsof"

    # With a deliberately minimal PATH, none of the optional process tools are
    # visible. The helper must distinguish that from a clean scan.
    local helper_out
    helper_out=$(HOME="$SB/home" PATH="$SB/bin" CLAUDE_PROFILES_DIR="$SB/home/.claude-profiles" \
        "$sh_abs" -c ". '$SRC'; _claude_profile_stale_processes; echo rc=\$?" 2>&1)
    assert_contains "missing process tools return the SKIP state" "rc=2" "$helper_out"

    printf '\n-- bin/ is not a profile --\n'
    mkdir -p "$SB/home/.claude-profiles/bin"
    out=$(run "claude-profile ls")
    assert_not_contains "ls does not list bin as a profile" "-bin" "$out"
    out=$(run "claude-profile new bin </dev/null; echo exit=\$?")
    assert_contains "cannot create a profile named bin" "exit=1" "$out"

    printf '\n-- spend --\n'
    if command -v python3 >/dev/null 2>&1; then
        # Planted transcripts with hand-computable costs, mid-month timestamps
        # so local-timezone month bucketing cannot straddle a boundary.
        #
        # Default profile, claude-opus-5 at $5/$25 per MTok:
        #   1M in + 1M out = $30.00 — plus an exact duplicate (same message id
        #   and requestId, as a resumed session leaves behind) that must be
        #   deduped, and a 2025-11 entry that must fall outside the month.
        mkdir -p "$SB/home/.claude/projects/-spend"
        cat > "$SB/home/.claude/projects/-spend/s1.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-01-15T10:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":1000000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","timestamp":"2026-01-15T10:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":1000000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","timestamp":"2025-11-15T10:00:00.000Z","requestId":"req_0","message":{"id":"msg_0","model":"claude-opus-5","usage":{"input_tokens":9000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"user","timestamp":"2026-01-15T10:00:01.000Z","message":{"role":"user","content":"noise line without usage"}}
JSONL
        # Work profile, claude-sonnet-5 at $3/$15 per MTok:
        #   1M out ($15) + 1M 5m-cache write at 1.25x ($3.75)
        #   + 1M 1h-cache write at 2x ($6) + 10M cache reads at 0.1x ($3)
        #   = $27.75. Grand total across profiles: $57.75.
        mkdir -p "$SB/home/.claude-profiles/work/projects/-spend"
        cat > "$SB/home/.claude-profiles/work/projects/-spend/s2.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-01-20T10:00:00.000Z","requestId":"req_2","message":{"id":"msg_2","model":"claude-sonnet-5","usage":{"input_tokens":0,"output_tokens":1000000,"cache_read_input_tokens":10000000,"cache_creation":{"ephemeral_5m_input_tokens":1000000,"ephemeral_1h_input_tokens":1000000}}}}
JSONL
        out=$(run "claude-profile spend 2026-01")
        # Single quotes are deliberate: these are literal dollar amounts to
        # match in the output, not expressions to expand.
        # shellcheck disable=SC2016
        assert_contains "spend prices the default profile" '$30.00' "$out"
        # shellcheck disable=SC2016
        assert_contains "spend prices the work profile" '$27.75' "$out"
        # shellcheck disable=SC2016
        assert_contains "spend totals across profiles" '$57.75' "$out"
        assert_not_contains "spend excludes other months" "9.0M" "$out"
        assert_contains "spend says it is a list-price figure" "list rates" "$out"

        out=$(run "claude-profile spend 2026-01 --models")
        assert_contains "spend --models names the model" "claude-sonnet-5" "$out"

        out=$(run "claude-profile spend 2026-01 --json")
        assert_contains "spend --json reports the total" '"total_usd": 57.75' "$out"

        out=$(run "claude-profile spend nonsense; echo exit=\$?")
        assert_contains "spend rejects a malformed month" "exit=1" "$out"
    else
        printf '  SKIP  python3 not installed\n'
    fi

    printf '\n-- codex: profile isolation --\n'
    out=$(run "claude-profile new cx </dev/null")
    assert_contains "new creates a codex home" "codex home:" "$out"
    assert_contains "new shares AGENTS.md" "linked AGENTS.md" "$out"
    assert_not_contains "new does not share config.toml" "config.toml" "$out"
    out=$(run "ls -1a \"\$CLAUDE_PROFILES_DIR/.codex/cx\"")
    assert_contains "codex home has AGENTS.md" "AGENTS.md" "$out"
    assert_not_contains "codex home has no config.toml" "config.toml" "$out"
    assert_not_contains "codex home has no auth.json link" "auth.json" "$out"

    out=$(run "codex -cx chat")
    assert_contains "codex profile sets CODEX_HOME" "/.claude-profiles/.codex/cx|args:chat" "$out"
    assert_contains "codex profile exports CLAUDE_PROFILE" "profile=cx" "$out"

    out=$(run "codex chat")
    assert_contains "bare codex leaves CODEX_HOME alone" "CODEX_HOME=<unset>|args:chat" "$out"

    printf '\n-- codex: never silently falls back --\n'
    out=$(run "codex -nosuch; echo exit=\$?")
    assert_contains "unknown codex profile refuses" "Refusing to fall back" "$out"
    assert_contains "unknown codex profile exits 2" "exit=2" "$out"
    assert_not_contains "unknown codex profile never runs codex" "STUB|CODEX_HOME" "$out"

    printf '\n-- codex: real flags must pass through --\n'
    for flag in -m -c -h -i -s -a --help --version; do
        out=$(run "codex $flag")
        assert_contains "codex flag $flag untouched" "CODEX_HOME=<unset>|args:$flag" "$out"
    done
    # -p is Codex's own config-profile flag. Swallowing it would silently
    # change which config.toml layer a session runs with.
    out=$(run "codex -p fast")
    assert_contains "codex -p reaches codex" "CODEX_HOME=<unset>|args:-p fast" "$out"
    out=$(run "codex -codexonly")
    assert_contains "unknown-but-real codex flag passes" "CODEX_HOME=<unset>|args:-codexonly" "$out"

    printf '\n-- codex: path traversal --\n'
    for bad in ".." "../../OUTSIDE" "/" "." "-dashy"; do
        out=$(run "codex '-$bad' 2>&1; echo exit=\$?")
        assert_not_contains "codex never resolves '-$bad' to a home" \
            "CODEX_HOME=$SB" "$out"
    done
    assert_contains "outside canary survives codex traversal" "OUTSIDE_CANARY" \
        "$(cat "$SB/OUTSIDE/canary.txt" 2>&1)"

    printf '\n-- codex: account shown, tokens never printed --\n'
    # A static id_token: base64url({"alg":"RS256"}).base64url({"email":...}).sig
    # Written literally rather than generated, so this suite never invokes
    # python3 itself — see the command-hash note in the fallback test above.
    cat > "$SB/home/.claude-profiles/.codex/cx/auth.json" <<'MKAUTH'
{"auth_mode": "chatgpt",
 "tokens": {"id_token": "eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6ImNvZGV4QGV4YW1wbGUuY29tIn0.SIGNATUREBLOB",
            "access_token": "ACCESSTOKENBLOB",
            "refresh_token": "REFRESHTOKENBLOB"}}
MKAUTH
    out=$(run "claude-profile ls")
    assert_contains "ls shows the codex account" "codex@example.com" "$out"
    assert_not_contains "ls never prints the access token" "ACCESSTOKENBLOB" "$out"
    assert_not_contains "ls never prints the refresh token" "REFRESHTOKENBLOB" "$out"
    assert_not_contains "ls never prints the signature" "SIGNATUREBLOB" "$out"

    printf '\n-- codex: a profile may exist for one runtime only --\n'
    mkdir -p "$SB/home/.claude-profiles/.codex/codexonly"
    out=$(run "claude-profile ls")
    assert_contains "codex-only profile is listed" "-codexonly" "$out"
    assert_contains "codex-only profile has no claude side" "(none)" "$out"
    out=$(run "codex -codexonly go")
    assert_contains "codex-only profile is usable" "/.codex/codexonly|args:go" "$out"

    printf '\n-- codex: .codex is not itself a profile --\n'
    out=$(run "claude-profile ls")
    assert_not_contains "ls does not list .codex as a profile" "-.codex" "$out"
    out=$(run "_claude_profiles_names")
    assert_not_contains "completion does not offer .codex" ".codex" "$out"
    out=$(run "claude -.codex 2>&1; echo exit=\$?")
    assert_not_contains "cannot run the .codex directory as a profile" "CLAUDE_CONFIG_DIR=$SB/home/.claude-profiles/.codex|" "$out"

    printf '\n-- codex: path and exec --\n'
    out=$(run "claude-profile path cx codex")
    assert_contains "path reports the codex home" "/.claude-profiles/.codex/cx" "$out"
    out=$(run "claude-profile path cx")
    assert_contains "path still defaults to claude" "/.claude-profiles/cx" "$out"
    out=$(run "claude-profile path cx bogusruntime; echo exit=\$?")
    assert_contains "path rejects an unknown runtime" "exit=1" "$out"
    out=$(run "claude-profile exec cx -- codex go")
    assert_contains "exec sets CODEX_HOME too" "/.claude-profiles/.codex/cx|args:go" "$out"
    out=$(run "claude-profile exec cx -- claude go")
    assert_contains "exec still sets CLAUDE_CONFIG_DIR" "/.claude-profiles/cx|args:go" "$out"

    printf '\n-- codex: deletion removes both sides --\n'
    out=$(run "printf 'cx\n' | claude-profile rm cx")
    assert_contains "rm deletes the profile" 'Deleted "cx"' "$out"
    out=$(run "ls -1a \"\$CLAUDE_PROFILES_DIR/.codex\"")
    assert_not_contains "codex home gone after delete" "cx" "$out"
    assert_contains "shared AGENTS.md intact" "REAL_AGENTS" "$(cat "$SB/home/.codex/AGENTS.md" 2>&1)"
    assert_contains "shared codex skill intact" "REAL_CODEX_SKILL" "$(cat "$SB/home/.codex/skills/keep.txt" 2>&1)"

    printf '\n-- codex: doctor and audit --\n'
    out=$(run "claude-profile doctor")
    assert_contains "doctor checks the codex wrapper" "codex wrapper active" "$out"
    assert_contains "doctor probes CODEX_HOME" "CODEX_HOME still honoured" "$out"
    out=$(run "claude-profile audit; echo exit=\$?")
    assert_contains "audit lists the codex shared list" "Shared list (codex)" "$out"
    assert_contains "clean codex audit exits 0" "exit=0" "$out"
    printf 'sk-ant-AAAAAAAAAAAAAAAAAAAA\n' > "$SB/home/.codex/AGENTS.md"
    out=$(run "claude-profile audit; echo exit=\$?")
    assert_contains "audit flags a secret in shared codex config" "AGENTS.md" "$out"
    assert_contains "dirty codex audit exits 1" "exit=1" "$out"
    echo "REAL_AGENTS" > "$SB/home/.codex/AGENTS.md"

    printf '\n-- pre-set CLAUDE_PROFILE_SHARED survives sourcing --\n'
    # run_pre <code before sourcing> <code after sourcing>
    run_pre() {
        HOME="$SB/home" PATH="$SB/bin:$PATH" \
            CLAUDE_PROFILES_DIR="$SB/home/.claude-profiles" \
            "$sh" -c "$1
. '$SRC'
$2" 2>&1
    }
    out=$(run_pre "CLAUDE_PROFILE_SHARED=''" "printf '[%s]\n' \"\$CLAUDE_PROFILE_SHARED\"")
    assert_contains "explicit empty shared list is honoured" "[]" "$out"
    out=$(run_pre "CLAUDE_PROFILE_SHARED='skills'" "printf '[%s]\n' \"\$CLAUDE_PROFILE_SHARED\"")
    assert_contains "custom shared list is honoured" "[skills]" "$out"
    out=$(run "printf '[%s]\n' \"\$CLAUDE_PROFILE_SHARED\"")
    assert_contains "unset shared list keeps the default" "[settings.json skills agents commands plugins CLAUDE.md]" "$out"
    out=$(run_pre "CLAUDE_PROFILE_SHARED=''" "claude-profile new standalone </dev/null; ls -1a \"\$CLAUDE_PROFILES_DIR/standalone\"")
    assert_contains "standalone profile is created" 'Created profile "standalone"' "$out"
    assert_not_contains "standalone profile shares no settings.json" "settings.json" "$out"
    out=$(run_pre "CODEX_PROFILE_SHARED=''" "_claude_profile_shared_items \"\$CODEX_PROFILE_SHARED\"")
    assert_not_contains "empty codex list does not fall back to the claude list" "settings.json" "$out"
    out=$(run "printf 'standalone\n' | claude-profile rm standalone")

    printf '\n-- traversal-shaped shared entries are skipped --\n'
    for bad in "../../OUTSIDE/escaped" ".." "." "sub/dir"; do
        out=$(run_pre "CLAUDE_PROFILE_SHARED='skills $bad'" "claude-profile new trav </dev/null")
        assert_contains "new warns on shared entry '$bad'" "skipping unsafe shared entry \"$bad\"" "$out"
        out=$(run "ls -1a \"\$CLAUDE_PROFILES_DIR/trav\" 2>&1")
        assert_contains "legit entry still linked alongside '$bad'" "skills" "$out"
        out=$(run_pre "CLAUDE_PROFILE_SHARED='skills $bad'" "claude-profile repair --all")
        assert_contains "repair warns on shared entry '$bad'" "skipping unsafe shared entry" "$out"
        out=$(run_pre "CLAUDE_PROFILE_SHARED='skills $bad'" "claude-profile audit")
        assert_contains "audit warns on shared entry '$bad'" "skipping unsafe shared entry" "$out"
        out=$(run "printf 'trav\n' | claude-profile rm trav")
    done
    # Set after sourcing too — the red team's original repro path.
    out=$(run "CLAUDE_PROFILE_SHARED='../../OUTSIDE/escaped'; claude-profile new trav </dev/null")
    assert_contains "post-source traversal entry is skipped" "skipping unsafe shared entry" "$out"
    out=$(run "printf 'trav\n' | claude-profile rm trav")
    assert_contains "no symlink escaped to \$SB/OUTSIDE" "absent" \
        "$([ -e "$SB/OUTSIDE/escaped" ] || [ -L "$SB/OUTSIDE/escaped" ] && echo present || echo absent)"
    assert_contains "no symlink escaped to \$HOME" "absent" \
        "$([ -L "$SB/home/escaped" ] && echo present || echo absent)"

    printf '\n-- zero-profile and codex-only states under %s --\n' "$sh"
    local EMPTY="$SB/empty-profiles"
    mkdir -p "$EMPTY/.codex/onlycodex"
    run_empty() {
        HOME="$SB/home" PATH="$SB/bin:$PATH" CLAUDE_PROFILES_DIR="$EMPTY" \
            "$sh" -c ". '$SRC'
$1" 2>&1
    }
    out=$(run_empty "claude-profile repair; echo exit=\$?")
    assert_not_contains "repair: no nomatch with only hidden dirs" "no matches found" "$out"
    assert_contains "repair reports no profiles" "No profiles yet" "$out"
    out=$(run_empty "claude-profile doctor; echo exit=\$?")
    assert_not_contains "doctor: no nomatch with only hidden dirs" "no matches found" "$out"
    assert_contains "doctor still lists the codex-only home" "onlycodex (codex only)" "$out"
    rm -rf "$EMPTY"; mkdir -p "$EMPTY"
    mv "$SB/home/.claude.json" "$SB/home/.claude.json.hold"
    out=$(run_empty "claude-profile audit; echo exit=\$?")
    assert_not_contains "audit: no nomatch with an empty profiles dir" "no matches found" "$out"
    assert_contains "audit says MCP check had nothing to inspect" "nothing to inspect" "$out"
    mv "$SB/home/.claude.json.hold" "$SB/home/.claude.json"
    rm -rf "$EMPTY"

    printf '\n-- repair never wires a dangling statusLine renderer --\n'
    local SETTINGS_HOLD
    SETTINGS_HOLD=$(cat "$SB/home/.claude/settings.json")
    rm -f "$SB/home/.claude/settings.json"
    printf '{}\n' > "$SB/home/.claude/settings.json"
    out=$(run_pre "CLAUDE_PROFILE_STATUS_BIN='$SB/nowhere/profile-status.sh'" "claude-profile repair; echo exit=\$?")
    assert_contains "repair warns when the renderer is missing" "NOT wiring statusLine" "$out"
    assert_contains "repair exits non-zero when the renderer is missing" "exit=1" "$out"
    assert_not_contains "settings.json not given a dangling statusLine" "statusLine" \
        "$(cat "$SB/home/.claude/settings.json")"
    if command -v python3 >/dev/null 2>&1; then
        out=$(run_pre "CLAUDE_PROFILE_STATUS_BIN='$STATUS_BIN'" "claude-profile repair; echo exit=\$?")
        assert_contains "repair wires a renderer that exists" "Added statusLine" "$out"
        assert_contains "settings.json points at the real renderer" "$STATUS_BIN" \
            "$(cat "$SB/home/.claude/settings.json")"
    fi
    rm -f "$SB/home/.claude/settings.json" "$SB/home/.claude/settings.json.bak-"*
    printf '%s\n' "$SETTINGS_HOLD" > "$SB/home/.claude/settings.json"

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
