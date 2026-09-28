#!/usr/bin/env bash
# claude-profiles — multiple Claude Code and Codex logins, one CLI
# https://github.com/kamtS/claude-profiles
#
# Requires bash or zsh. The body is otherwise POSIX-flavoured, but the
# `claude-profile` function name contains a hyphen, which bash and zsh
# accept and strict POSIX sh does not — so source it from bash or zsh.
#
# Source this from your ~/.zshrc or ~/.bashrc:
#     [ -f "$HOME/.claude-profiles/claude-profiles.sh" ] \
#         && . "$HOME/.claude-profiles/claude-profiles.sh"
#
# Usage:
#     claude                  default profile (~/.claude, untouched)
#     claude -work [args...]  run against the "work" profile
#     codex  -work [args...]  same profile, Codex instead of Claude Code
#     claude-profile new work create a profile and log into it
#     claude-profile ls       list profiles and their accounts
#     claude-profile rm work  delete a profile
#
# How it works: Claude Code reads CLAUDE_CONFIG_DIR to decide where its
# config, credentials, MCP servers and history live. This wrapper swaps
# that directory based on a leading -<name> argument. On macOS the OS
# keychain namespaces credentials per config dir, so logins never collide.
#
# Codex works the same way through CODEX_HOME, and is in one respect easier:
# it keeps its credentials in $CODEX_HOME/auth.json on disk rather than in the
# keychain, so a separate home is a separate login with nothing shared. Both
# wrappers refuse to fall back to the default profile when a -<name> argument
# names no profile, because a silent fallback bills the wrong account.
#
# Licensed under the MIT License.

# Where profiles live. Override before sourcing to relocate.
CLAUDE_PROFILES_DIR="${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"

# Config shared (by symlink) into each new profile, so only credentials,
# history and MCP auth diverge. Edit to taste; entries that don't exist
# in ~/.claude are skipped.
#
# Nothing in this list may carry secrets: a shared file is loaded into every
# client's session. `claude-profile audit` enforces that. Note that MCP server
# definitions — the usual place inline API keys and OAuth tokens end up — live
# in .claude.json INSIDE each config dir and are never shared by this list.
#
# Set it before sourcing to override; an explicit empty value ("") means fully
# standalone profiles and is honoured. `-`, not `:-`, is deliberate: `:-` would
# treat "" as unset and silently share everything into an isolated profile.
CLAUDE_PROFILE_SHARED="${CLAUDE_PROFILE_SHARED-settings.json skills agents commands plugins CLAUDE.md}"

# Codex homes live in a hidden sibling directory of the Claude profile dirs,
# so one profile name means the same client in both runtimes and a single
# directory still holds everything worth backing up. The leading dot is what
# keeps it out of profile enumeration: _claude_profile_valid_name rejects any
# name that does not start with an alphanumeric, so ".codex" can never be
# mistaken for a profile of its own.
CODEX_PROFILES_SUBDIR=".codex"

# Config shared (by symlink) into each new Codex home. As with the Claude
# list, nothing here may carry secrets, and `claude-profile audit` enforces it.
#
# Two deliberate omissions. config.toml is absent because it is Codex's
# equivalent of a credential store-adjacent file: it holds `env_key`, MCP
# server definitions and other settings that hand a session credentials.
# `memories` is absent because it is accumulated per-client context rather
# than configuration — sharing it would leak one client's working notes into
# another client's session, which is the whole thing profiles exist to stop.
CODEX_PROFILE_SHARED="${CODEX_PROFILE_SHARED-AGENTS.md skills prompts rules plugins}"

# Where the statusLine renderer lives. This is where install.sh puts it — it is
# NOT derived from wherever this script was sourced from, so a hand-install
# that skips install.sh must set it explicitly (repair refuses to wire a
# renderer that is not there).
CLAUDE_PROFILE_STATUS_BIN="${CLAUDE_PROFILE_STATUS_BIN:-$CLAUDE_PROFILES_DIR/bin/profile-status.sh}"

# --- internals ---------------------------------------------------------------

# Profile names become path segments, so they are strictly validated:
# must start alphanumeric, then alphanumerics, dot, underscore or hyphen.
# This rejects "", ".", "..", anything containing "/", and leading dashes.
_claude_profile_valid_name() {
    case "$1" in
        "" | . | ..) return 1 ;;
        *[!A-Za-z0-9._-]* | [!A-Za-z0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# A single-character profile would shadow a real Claude Code short flag
# (-c, -p, -d, -r, -v, -w, -n, -h) once the profile directory exists, and
# the wrapper would silently swallow it. Reject them at creation time
# rather than let someone break `claude -p` for themselves later.
_claude_profile_name_is_reserved() {
    case "$1" in
        ?) return 0 ;;
        *) return 1 ;;
    esac
}

# The profiles directory also holds the script itself and bin/, so not every
# subdirectory in there is a profile.
_claude_profile_is_reserved_dir() {
    case "$1" in
        bin) return 0 ;;
        *) return 1 ;;
    esac
}

# True when $1 names a real profile directory: valid name, not reserved,
# and actually present. The single place that decision is made.
_claude_profile_exists() {
    _claude_profile_valid_name "$1" || return 1
    _claude_profile_is_reserved_dir "$1" && return 1
    [ -d "$CLAUDE_PROFILES_DIR/$1" ]
}

# Path to the real claude binary, skipping our own shell function.
_claude_profile_bin() {
    if [ -n "$ZSH_VERSION" ]; then
        whence -p claude 2>/dev/null
    else
        type -P claude 2>/dev/null
    fi
}

# Emit PID|executable for running Claude processes whose executable has been
# removed from disk. Package-manager upgrades can leave old interactive
# sessions alive from an `.upgrading` path after installing a new binary. That
# stale cross-version state has been observed alongside otherwise context-free
# EPERM launch failures and is an actionable diagnostic lead. Return 2 when the
# optional process-inspection tools are unavailable so doctor can say SKIP
# rather than claim the machine is clean.
_claude_profile_stale_processes() {
    command -v id >/dev/null 2>&1 || return 2
    command -v pgrep >/dev/null 2>&1 || return 2
    command -v lsof >/dev/null 2>&1 || return 2

    _cp_uid=$(id -u 2>/dev/null) || return 2
    case "$_cp_uid" in
        "" | *[!0-9]*) return 2 ;;
    esac

    pgrep -u "$_cp_uid" -x claude 2>/dev/null | while IFS= read -r _cp_pid; do
        case "$_cp_pid" in
            "" | *[!0-9]*) continue ;;
        esac
        _cp_exe=$(lsof -a -p "$_cp_pid" -d txt -Fn 2>/dev/null |
            sed -n 's/^n//p' | head -n 1)
        [ -n "$_cp_exe" ] || continue
        [ -e "$_cp_exe" ] || printf '%s|%s\n' "$_cp_pid" "$_cp_exe"
    done
    unset _cp_uid _cp_pid _cp_exe
}

# Resolve a profile name to its directory, or fail. Never interpolates an
# unvalidated name into a path.
_claude_profile_dir() {
    _claude_profile_valid_name "$1" || return 1
    printf '%s\n' "$CLAUDE_PROFILES_DIR/$1"
}

# Print the account email recorded in a .claude.json, or a fallback.
# Tries python3, then node, then a grep/sed fallback so the tool still
# works on a machine with neither runtime installed.
_claude_profile_account() {
    _cp_json="$1"
    if [ ! -f "$_cp_json" ]; then
        printf 'not logged in\n'
        return 0
    fi

    _cp_email=""
    if command -v python3 >/dev/null 2>&1; then
        _cp_email=$(python3 -c '
import json, sys
try:
    acct = json.load(open(sys.argv[1])).get("oauthAccount") or {}
except Exception:
    sys.exit(0)
print(acct.get("emailAddress") or "")
' "$_cp_json" 2>/dev/null)
    elif command -v node >/dev/null 2>&1; then
        _cp_email=$(node -e '
try {
  const a = (JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).oauthAccount) || {};
  process.stdout.write(a.emailAddress || "");
} catch (e) {}
' "$_cp_json" 2>/dev/null)
    else
        _cp_email=$(grep -o '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' "$_cp_json" 2>/dev/null |
            head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
    fi

    if [ -n "$_cp_email" ]; then
        printf '%s\n' "$_cp_email"
    elif [ -s "$_cp_json" ]; then
        printf 'no OAuth login recorded\n'
    else
        printf 'not logged in\n'
    fi
    unset _cp_json _cp_email
}

# Is "$1" (with its leading dash) a real Claude Code flag rather than a typo'd
# profile name? Consulted only on the failure path, so the common case pays
# nothing. The static list is today's short flags; the `--help` scrape is the
# part that survives a future release adding a new one, which is exactly the
# kind of quiet drift that would otherwise turn a real flag into a hard error.
# True when $2 is a genuine single-dash flag of the runtime named by $1, and
# so must be passed through rather than treated as a profile name. The known
# short flags are listed explicitly per runtime so the check still gives the
# right answer when the binary is missing or `--help` cannot be run; anything
# else is confirmed against that runtime's own help text.
_ap_is_real_flag() {
    case "$1" in
        claude)
            case "$2" in
                -c | -d | -h | -n | -p | -r | -v | -w) return 0 ;;
            esac
            ;;
        codex)
            # Codex 0.154's single-dash flags. Note -p: Codex uses it for its
            # own config profiles (layering $CODEX_HOME/<name>.config.toml),
            # which are a different concept from these account profiles. It
            # passes through to Codex untouched.
            case "$2" in
                -a | -c | -C | -h | -i | -m | -p | -s | -V) return 0 ;;
            esac
            ;;
    esac
    command -v "$1" >/dev/null 2>&1 || return 1
    command "$1" --help 2>/dev/null |
        grep -qE "(^|[[:space:],])$(printf '%s' "$2" | sed 's/[^A-Za-z0-9-]/./g')([[:space:],]|$)"
}

# Kept for compatibility with anything that called the original name.
_claude_profile_is_real_flag() {
    _ap_is_real_flag claude "$1"
}

# Decide whether a leading -<name> argument claims a profile, for either
# runtime. Prints the profile directory on stdout when it does.
#
#   0  claimed  — caller should shift and use the printed directory
#   1  not profile-shaped, or a genuine flag — pass it through untouched
#   2  profile-shaped but no such profile — refuse, message already on stderr
#
# Both wrappers share this so the refusal logic cannot drift between them:
# an unmatched profile-shaped argument must never silently fall back to the
# default profile, in either runtime.
_ap_claim_profile() {
    _ap_rt="$1"
    _ap_root="$2"
    _ap_arg="${3:-}"

    case "$_ap_arg" in
        --* | "") unset _ap_rt _ap_root _ap_arg; return 1 ;;
        -?*) ;;
        *) unset _ap_rt _ap_root _ap_arg; return 1 ;;
    esac

    _ap_name="${_ap_arg#-}"
    if ! _claude_profile_valid_name "$_ap_name"; then
        unset _ap_rt _ap_root _ap_arg _ap_name
        return 1
    fi

    if ! _claude_profile_is_reserved_dir "$_ap_name" && [ -d "$_ap_root/$_ap_name" ]; then
        printf '%s\n' "$_ap_root/$_ap_name"
        unset _ap_rt _ap_root _ap_arg _ap_name
        return 0
    fi

    if _ap_is_real_flag "$_ap_rt" "$_ap_arg"; then
        unset _ap_rt _ap_root _ap_arg _ap_name
        return 1
    fi

    printf 'claude-profile: no %s profile "%s" in %s\n' \
        "$_ap_rt" "$_ap_name" "$_ap_root" >&2
    printf 'Refusing to fall back to the default profile.\n' >&2
    printf 'Run "claude-profile ls" to see what exists.\n' >&2
    unset _ap_rt _ap_root _ap_arg _ap_name
    return 2
}

# Emit the shared-config entries, one per line. $1 is the space-separated
# list, defaulting to the Claude one so existing callers are unchanged. The
# default applies only when no argument is passed: an explicitly empty Codex
# list must stay empty, not fall back to the Claude one.
# Iterate via `tr` + `read`, NOT `for x in $CLAUDE_PROFILE_SHARED`: zsh does not
# word-split unquoted scalars, so a plain `for` loop silently iterated nothing.
#
# Each entry becomes a path segment under a profile dir and under ~/.claude, so
# anything that could escape either (".", "..", or anything containing "/") is
# skipped with a warning on stderr rather than linked or scanned.
_claude_profile_shared_items() {
    if [ $# -gt 0 ]; then _cp_list="$1"; else _cp_list="$CLAUDE_PROFILE_SHARED"; fi
    printf '%s\n' "$_cp_list" | tr ' ' '\n' | while IFS= read -r _cp_i; do
        case "$_cp_i" in
            "") ;;
            . | .. | */*)
                printf 'claude-profile: skipping unsafe shared entry "%s" (must be a plain name)\n' \
                    "$_cp_i" >&2
                ;;
            *) printf '%s\n' "$_cp_i" ;;
        esac
    done
    unset _cp_list
}

# Link one shared entry into a profile. $3 is the directory the canonical copy
# lives in, defaulting to ~/.claude so existing callers are unchanged. Reports
# what it did on stdout so the caller can summarise. Never clobbers an entry.
_claude_profile_link_item() {
    _cp_t="${3:-$HOME/.claude}/$2"
    _cp_l="$1/$2"
    [ -e "$_cp_t" ] || return 0
    if [ -L "$_cp_l" ]; then
        return 0
    elif [ -e "$_cp_l" ]; then
        # A real file where a symlink belongs. This is what an atomic
        # temp-file-plus-rename settings write looks like after the fact: the
        # profile quietly stopped sharing. Never discard it — the divergent
        # copy is the only record of whatever was changed.
        _cp_bak="$_cp_l.unshared-$(date +%Y%m%d%H%M%S)"
        mv "$_cp_l" "$_cp_bak" 2>/dev/null || return 1
        ln -s "$_cp_t" "$_cp_l" 2>/dev/null || return 1
        printf 'relinked %s (previous copy kept at %s)\n' "$2" "$_cp_bak"
    else
        ln -s "$_cp_t" "$_cp_l" 2>/dev/null && printf 'linked %s\n' "$2"
    fi
    unset _cp_t _cp_l _cp_bak
}

# --- codex -------------------------------------------------------------------

# The directory holding every Codex home, one per profile.
_codex_profile_root() {
    printf '%s\n' "$CLAUDE_PROFILES_DIR/$CODEX_PROFILES_SUBDIR"
}

# Resolve a profile name to its Codex home, or fail. Never interpolates an
# unvalidated name into a path.
_codex_profile_home() {
    _claude_profile_valid_name "$1" || return 1
    printf '%s\n' "$(_codex_profile_root)/$1"
}

# True when $1 has a Codex home. A profile can legitimately exist for one
# runtime and not the other, so this is asked separately from the Claude one.
_codex_profile_exists() {
    _claude_profile_valid_name "$1" || return 1
    _claude_profile_is_reserved_dir "$1" && return 1
    [ -d "$(_codex_profile_root)/$1" ]
}

# Path to the real codex binary, skipping our own shell function.
_codex_profile_bin() {
    if [ -n "$ZSH_VERSION" ]; then
        whence -p codex 2>/dev/null
    else
        type -P codex 2>/dev/null
    fi
}

# Print the account recorded in a Codex home, or a fallback.
#
# Codex stores credentials in $CODEX_HOME/auth.json. The signed-in address is
# the `email` claim of the OIDC id_token in there, so this decodes the JWT
# payload - the middle, unsigned, base64url segment - and reads that one claim.
# It deliberately never prints, logs or returns any part of the tokens
# themselves; `ls` output should be safe to paste into a ticket.
_codex_profile_account() {
    _cp_auth="$1/auth.json"
    if [ ! -f "$_cp_auth" ]; then
        printf 'not logged in\n'
        unset _cp_auth
        return 0
    fi

    _cp_who=""
    if command -v python3 >/dev/null 2>&1; then
        _cp_who=$(python3 - "$_cp_auth" <<'CODEXAUTHEOF' 2>/dev/null
import base64, json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
tok = data.get("tokens")
raw = tok.get("id_token") if isinstance(tok, dict) else None
if isinstance(raw, str) and raw.count(".") == 2:
    seg = raw.split(".")[1]
    seg += "=" * (-len(seg) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(seg))
    except Exception:
        claims = {}
    # The email claim only. Nothing else from the token is read or printed.
    email = claims.get("email") if isinstance(claims, dict) else None
    if isinstance(email, str) and email:
        print(email)
        sys.exit(0)
if data.get("OPENAI_API_KEY"):
    print("API key")
    sys.exit(0)
mode = data.get("auth_mode")
print(mode if isinstance(mode, str) and mode else "logged in")
CODEXAUTHEOF
        )
    fi
    if [ -z "$_cp_who" ]; then
        # No python3, or an auth.json this version does not understand. Say
        # something true rather than guessing at an account.
        _cp_who="logged in (details need python3)"
    fi
    printf '%s\n' "$_cp_who"
    unset _cp_auth _cp_who
}

# Scan a path for credential-shaped content. Prints "path: KEY" lines — key
# names only, never values, because the output of an audit should itself be
# safe to paste into a ticket.
_claude_profile_scan_secrets() {
    [ -e "$1" ] || return 0
    grep -rIlE '(sk-ant-[A-Za-z0-9_-]{16}|ghp_[A-Za-z0-9]{16}|gho_[A-Za-z0-9]{16}|xoxb-[0-9]{8}|AIza[0-9A-Za-z_-]{30})' \
        "$1" 2>/dev/null | while IFS= read -r _cp_f; do
        printf '%s: hard-coded credential pattern\n' "$_cp_f"
    done
    # Settings keys that grant a session credentials or the authority to fetch
    # them. Harmless in isolation; dangerous in a file shared across clients.
    grep -rIlE '"(apiKeyHelper|awsAuthRefresh|awsCredentialExport)"' "$1" 2>/dev/null |
        while IFS= read -r _cp_f; do
            printf '%s: credential-granting setting\n' "$_cp_f"
        done
    # An `env` block in shared settings is injected into every profile, so its
    # variable NAMES are worth listing (never the values). Parsed rather than
    # grepped: pretty-printed JSON puts the opening brace and the first key on
    # different lines, which a single-line regex silently misses.
    case "$1" in
        *settings.json)
            [ -f "$1" ] || return 0
            if command -v python3 >/dev/null 2>&1; then
                python3 - "$1" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
env = data.get("env") if isinstance(data, dict) else None
if isinstance(env, dict) and env:
    for key in sorted(env):
        print("%s: env var %s injected into every profile" % (sys.argv[1], key))
PYEOF
            else
                grep -qE '"env"[[:space:]]*:[[:space:]]*\{' "$1" 2>/dev/null &&
                    printf '%s: env block in shared settings\n' "$1"
            fi
            ;;
    esac
    unset _cp_f
}

# --- the wrapper -------------------------------------------------------------

# Claim a leading single-dash argument when it names an existing profile.
# When it does not, the old behaviour was to pass it through to Claude Code
# unchanged — which meant `claude -clienta` after a rename, a moved
# CLAUDE_PROFILES_DIR, or a plain typo ran the DEFAULT profile without a
# word. For anyone billing clients per profile that is the worst possible
# failure: silent, and wrong in the expensive direction. So an unmatched
# profile-shaped argument is a hard error, and only arguments that are
# genuinely flags of that runtime pass through. Both wrappers share
# _ap_claim_profile so that rule cannot drift between them.
claude() {
    _cp_dir=$(_ap_claim_profile claude "$CLAUDE_PROFILES_DIR" "${1:-}")
    _cp_rc=$?
    if [ "$_cp_rc" -eq 2 ]; then
        unset _cp_dir _cp_rc
        return 2
    fi
    if [ "$_cp_rc" -eq 0 ]; then
        shift
        # CLAUDE_PROFILE is exported for anything downstream that wants to show
        # the profile too — a shell prompt, tmux, a hook.
        [ -n "${CLAUDE_PROFILE_QUIET:-}" ] ||
            printf 'claude-profiles: %s → %s\n' "$(basename "$_cp_dir")" "$_cp_dir" >&2
        CLAUDE_CONFIG_DIR="$_cp_dir" CLAUDE_PROFILE="$(basename "$_cp_dir")" \
            command claude "$@"
        _cp_rc=$?
        unset _cp_dir
        return $_cp_rc
    fi
    unset _cp_dir _cp_rc
    command claude "$@"
}

# The same wrapper for Codex, over CODEX_HOME instead of CLAUDE_CONFIG_DIR.
#
# Codex has no status line, so the launch banner on stderr is the only thing
# telling you which account a session is about to bill. That makes it more
# important here than it is for Claude Code, not less — CLAUDE_PROFILE_QUIET
# silences it, but think twice before setting that.
codex() {
    _cp_dir=$(_ap_claim_profile codex "$(_codex_profile_root)" "${1:-}")
    _cp_rc=$?
    if [ "$_cp_rc" -eq 2 ]; then
        unset _cp_dir _cp_rc
        return 2
    fi
    if [ "$_cp_rc" -eq 0 ]; then
        shift
        [ -n "${CLAUDE_PROFILE_QUIET:-}" ] ||
            printf 'claude-profiles: codex %s → %s\n' "$(basename "$_cp_dir")" "$_cp_dir" >&2
        CODEX_HOME="$_cp_dir" CLAUDE_PROFILE="$(basename "$_cp_dir")" \
            command codex "$@"
        _cp_rc=$?
        unset _cp_dir
        return $_cp_rc
    fi
    unset _cp_dir _cp_rc
    command codex "$@"
}

# --- the manager -------------------------------------------------------------

claude_profile_usage() {
    cat <<'EOF'
claude-profile — manage Claude Code and Codex workspace profiles

  claude-profile new <name>    create a profile, then log into it
  claude-profile ls            list profiles and the accounts each holds
  claude-profile rm <name>     delete a profile, both runtimes
  claude-profile path <name> [claude|codex]
                               print a profile's config directory
  claude-profile exec <name> [--] <cmd...>
                               run a command against a profile, for scripts
  claude-profile audit [name]  check shared config for credentials
  claude-profile spend [YYYY-MM] [--models] [--json]
                               the month's usage per profile: Claude priced
                               at API list rates, Codex in tokens
  claude-profile doctor        check the install still works after an update
  claude-profile repair [name|--all]
                               restore shared links and the status line

Once created, run either runtime against a profile by prefixing its name:

  claude -<name> [args...]
  codex  -<name> [args...]

One name means the same client in both. A profile may exist for only one
runtime; the other simply shows as "(none)" in `ls`.

That prefix works only in an interactive shell, because it is a shell
function. In scripts, cron jobs and CI — where ~/.zshrc is never sourced —
use `claude-profile exec <name> -- claude -p '...'` instead. Calling
`claude` or `codex` directly there silently uses the DEFAULT profile.

Names must start with a letter or digit and contain only letters, digits,
dot, underscore or hyphen.
EOF
}

claude-profile() {
    _cp_cmd="${1:-ls}"
    [ $# -gt 0 ] && shift

    case "$_cp_cmd" in
        new | add | create)
            _cp_name="$1"
            if ! _claude_profile_valid_name "$_cp_name"; then
                printf 'claude-profile: invalid profile name: %s\n' "${_cp_name:-<empty>}" >&2
                printf 'Names must start with a letter or digit, and contain only\n' >&2
                printf 'letters, digits, dot, underscore or hyphen.\n' >&2
                return 1
            fi
            if _claude_profile_is_reserved_dir "$_cp_name"; then
                printf 'claude-profile: "%s" is reserved — claude-profiles keeps its\n' "$_cp_name" >&2
                printf 'own files under that name. Pick another.\n' >&2
                return 1
            fi
            if _claude_profile_name_is_reserved "$_cp_name"; then
                printf 'claude-profile: "%s" is too short to be safe.\n' "$_cp_name" >&2
                printf 'Single-character names collide with Claude Code short flags\n' >&2
                printf 'such as -c, -p and -r. Pick a longer name.\n' >&2
                return 1
            fi
            if ! command -v claude >/dev/null 2>&1; then
                printf 'claude-profile: the "claude" CLI is not on your PATH.\n' >&2
                printf 'Install Claude Code first: https://claude.com/claude-code\n' >&2
                return 1
            fi

            _cp_dir="$CLAUDE_PROFILES_DIR/$_cp_name"
            if [ -e "$_cp_dir" ]; then
                printf 'claude-profile: profile "%s" already exists at %s\n' "$_cp_name" "$_cp_dir" >&2
                return 1
            fi

            mkdir -p "$_cp_dir" || return 1
            chmod 700 "$_cp_dir" 2>/dev/null

            # Share non-account-specific config from the default profile. The
            # `ln` calls run in a subshell; their filesystem effects persist,
            # and the linked names come back on stdout.
            _cp_linked=$(_claude_profile_shared_items | while IFS= read -r _cp_item; do
                _claude_profile_link_item "$_cp_dir" "$_cp_item"
            done)

            printf 'Created profile "%s"\n' "$_cp_name"
            printf '  config dir: %s\n' "$_cp_dir"
            if [ -n "$_cp_linked" ]; then
                printf '  shared from ~/.claude:\n'
                printf '%s\n' "$_cp_linked" | sed 's/^/    /'
            else
                printf '  shared from ~/.claude: nothing found to share\n'
            fi

            # Codex home for the same profile name. Created up front, before
            # either login, so the directory exists however the logins go.
            _cp_codex=""
            if command -v codex >/dev/null 2>&1; then
                _cp_codex="$(_codex_profile_root)/$_cp_name"
                if mkdir -p "$_cp_codex" 2>/dev/null; then
                    chmod 700 "$_cp_codex" 2>/dev/null
                    _cp_linked=$(_claude_profile_shared_items "$CODEX_PROFILE_SHARED" |
                        while IFS= read -r _cp_item; do
                            _claude_profile_link_item "$_cp_codex" "$_cp_item" "$HOME/.codex"
                        done)
                    printf '  codex home: %s\n' "$_cp_codex"
                    if [ -n "$_cp_linked" ]; then
                        printf '  shared from ~/.codex:\n'
                        printf '%s\n' "$_cp_linked" | sed 's/^/    /'
                    else
                        printf '  shared from ~/.codex: nothing found to share\n'
                    fi
                else
                    printf '  codex home: could not create %s\n' "$_cp_codex"
                    _cp_codex=""
                fi
            fi

            # Make sure the session will say which profile it is billing.
            if ! grep -q '"statusLine"' "$HOME/.claude/settings.json" 2>/dev/null; then
                printf '\nNote: no statusLine configured, so sessions will not display\n'
                printf 'which profile they are running as. Run: claude-profile repair\n'
            fi
            printf '\nStarting Claude Code in this profile so you can log in.\n'
            printf 'If it does not prompt automatically, run /login.\n\n'
            CLAUDE_CONFIG_DIR="$_cp_dir" command claude
            printf '\nDone. Use this profile any time with: claude -%s\n' "$_cp_name"

            if [ -n "$_cp_codex" ]; then
                # Codex logins are separate: separate home, separate auth.json,
                # separate account. Offered rather than forced, because plenty
                # of profiles will only ever be used from one runtime.
                printf 'Log into Codex for this profile too? [y/N] '
                read -r _cp_reply
                case "$_cp_reply" in
                    [Yy]*)
                        CODEX_HOME="$_cp_codex" CLAUDE_PROFILE="$_cp_name" \
                            command codex login
                        printf '\nAnd with: codex -%s\n' "$_cp_name"
                        ;;
                    *)
                        printf 'Skipped. Log in later with: codex -%s login\n' "$_cp_name"
                        ;;
                esac
            fi
            unset _cp_name _cp_dir _cp_item _cp_codex _cp_reply
            ;;

        ls | list)
            printf '%-16s %-34s %s\n' "PROFILE" "CLAUDE" "CODEX"
            # The default profile keeps its config JSON at ~/.claude.json,
            # not inside ~/.claude/. Codex's default home is ~/.codex.
            printf '%-16s %-34s %s\n' "(default)" \
                "$(_claude_profile_account "$HOME/.claude.json")" \
                "$(_codex_profile_account "$HOME/.codex")"

            # A profile can exist for one runtime and not the other, so the
            # two directory trees are unioned rather than one driving the list.
            {
                if [ -d "$CLAUDE_PROFILES_DIR" ]; then
                    # find, not a glob: portable across bash and zsh, and safe
                    # when the directory is empty.
                    find "$CLAUDE_PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null
                fi
                if [ -d "$(_codex_profile_root)" ]; then
                    find "$(_codex_profile_root)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null
                fi
            } | while IFS= read -r _cp_d; do
                basename "$_cp_d"
            done | sort -u | while IFS= read -r _cp_n; do
                _claude_profile_valid_name "$_cp_n" || continue
                _claude_profile_is_reserved_dir "$_cp_n" && continue
                if _claude_profile_exists "$_cp_n"; then
                    _cp_a=$(_claude_profile_account "$CLAUDE_PROFILES_DIR/$_cp_n/.claude.json")
                else
                    _cp_a="(none)"
                fi
                if _codex_profile_exists "$_cp_n"; then
                    _cp_b=$(_codex_profile_account "$(_codex_profile_root)/$_cp_n")
                else
                    _cp_b="(none)"
                fi
                printf '%-16s %-34s %s\n' "-$_cp_n" "$_cp_a" "$_cp_b"
            done
            unset _cp_d _cp_n _cp_a _cp_b
            ;;

        rm | remove | delete)
            _cp_name="$1"
            if ! _claude_profile_valid_name "$_cp_name"; then
                printf 'claude-profile: invalid profile name: %s\n' "${_cp_name:-<empty>}" >&2
                return 1
            fi
            _cp_dir="$CLAUDE_PROFILES_DIR/$_cp_name"

            _cp_codex="$(_codex_profile_root)/$_cp_name"

            # Belt and braces: the name is already validated, but confirm each
            # target really is a direct child of the profiles directory and
            # not a symlink pointing somewhere else before removing anything.
            for _cp_t in "$_cp_dir" "$_cp_codex"; do
                if [ -L "$_cp_t" ]; then
                    printf 'claude-profile: "%s" is a symlink; refusing to delete.\n' "$_cp_t" >&2
                    unset _cp_t
                    return 1
                fi
                case "$_cp_t" in
                    "$CLAUDE_PROFILES_DIR"/*) ;;
                    *)
                        printf 'claude-profile: refusing to delete outside %s\n' "$CLAUDE_PROFILES_DIR" >&2
                        unset _cp_t
                        return 1
                        ;;
                esac
            done
            unset _cp_t

            # A profile may legitimately exist for only one runtime.
            if [ ! -d "$_cp_dir" ] && [ ! -d "$_cp_codex" ]; then
                printf 'claude-profile: no such profile: %s\n' "$_cp_name" >&2
                return 1
            fi

            printf 'Delete profile "%s"?\n' "$_cp_name"
            [ -d "$_cp_dir" ] && printf '  claude: %s\n' "$_cp_dir"
            [ -d "$_cp_codex" ] && printf '  codex:  %s\n' "$_cp_codex"
            printf 'Its logins, history and MCP auth will be removed. Type the name to confirm: '
            read -r _cp_reply
            if [ "$_cp_reply" != "$_cp_name" ]; then
                printf 'Aborted.\n'
                unset _cp_name _cp_dir _cp_codex _cp_reply
                return 1
            fi
            # rm -rf removes symlinks themselves, never their targets, so the
            # shared ~/.claude and ~/.codex config is not at risk here.
            [ -d "$_cp_dir" ] && rm -rf "$_cp_dir"
            [ -d "$_cp_codex" ] && rm -rf "$_cp_codex"
            printf 'Deleted "%s".\n' "$_cp_name"
            printf 'Note: its keychain credential entry is left in place; remove it\n'
            printf 'manually from Keychain Access if you want it gone.\n'
            unset _cp_name _cp_dir _cp_codex _cp_reply
            ;;

        exec)
            # The wrapper is a shell function, so it does not exist in a
            # non-interactive shell — the one place a wrong profile would go
            # completely unseen, because print mode renders no status line
            # either. This subcommand is the supported path for scripts.
            _cp_name="$1"
            [ $# -gt 0 ] && shift
            if ! _claude_profile_valid_name "$_cp_name"; then
                printf 'claude-profile: invalid profile name: %s\n' "${_cp_name:-<empty>}" >&2
                return 1
            fi
            if ! _claude_profile_exists "$_cp_name" && ! _codex_profile_exists "$_cp_name"; then
                printf 'claude-profile: no such profile: %s\n' "$_cp_name" >&2
                return 2
            fi
            _cp_dir="$CLAUDE_PROFILES_DIR/$_cp_name"
            _cp_codex="$(_codex_profile_root)/$_cp_name"
            [ "$1" = "--" ] && shift
            if [ $# -eq 0 ]; then
                set -- claude
            fi
            # Both variables are set regardless of which binary is being run,
            # and regardless of whether that runtime's directory exists yet.
            # Pointing CODEX_HOME at an absent home makes Codex start there
            # unauthenticated, which fails loudly; leaving it unset would send
            # it to the default account, which is the silent failure this
            # whole tool exists to prevent.
            CLAUDE_CONFIG_DIR="$_cp_dir" CODEX_HOME="$_cp_codex" \
                CLAUDE_PROFILE="$_cp_name" command "$@"
            _cp_rc=$?
            unset _cp_name _cp_dir _cp_codex
            return $_cp_rc
            ;;

        audit)
            _cp_rc=0
            printf 'Auditing config shared across profiles.\n'
            printf 'Shared list (claude): %s\n' "$CLAUDE_PROFILE_SHARED"
            printf 'Shared list (codex):  %s\n\n' "$CODEX_PROFILE_SHARED"

            _cp_found=$(
                _claude_profile_shared_items | while IFS= read -r _cp_item; do
                    _claude_profile_scan_secrets "$HOME/.claude/$_cp_item"
                done
                _claude_profile_shared_items "$CODEX_PROFILE_SHARED" |
                    while IFS= read -r _cp_item; do
                        _claude_profile_scan_secrets "$HOME/.codex/$_cp_item"
                    done
            )

            if [ -n "$_cp_found" ]; then
                printf 'FINDINGS — these are shared into every profile:\n'
                printf '%s\n' "$_cp_found" | sed 's/^/  /'
                printf '\nA shared file carrying credentials means one client session\n'
                printf 'runs with another client credentials loaded. Either remove the\n'
                printf 'secret, or drop that entry from the relevant shared list.\n'
                _cp_rc=1
            else
                printf 'No credential-shaped content in shared config.\n'
            fi

            # MCP servers are the classic inline-token offender. They live in
            # .claude.json inside each config dir, which is never shared — so
            # this is a check that the isolation still holds, not a scan of
            # the shared list.
            # find, not a glob. Under zsh an unmatched glob is a hard error
            # (nomatch), so a `for x in dir/*/file` loop aborts the whole audit
            # on a machine that has no profiles yet — and the Codex tree is
            # empty exactly like that until the first Codex profile is made.
            #
            # The listing is built first and inspected afterwards rather than
            # setting _cp_rc inside a `while read` loop: that loop is on the
            # right of a pipe, so it runs in a subshell and any exit code set
            # there would be silently discarded.
            printf '\nMCP isolation:\n'
            _cp_iso=$(
                {
                    [ -f "$HOME/.claude.json" ] && printf '%s\n' "$HOME/.claude.json"
                    [ -d "$CLAUDE_PROFILES_DIR" ] &&
                        find "$CLAUDE_PROFILES_DIR" -mindepth 2 -maxdepth 2 \
                            -name '.claude.json' 2>/dev/null | sort
                } | while IFS= read -r _cp_j; do
                    [ -f "$_cp_j" ] || continue
                    if [ -L "$_cp_j" ]; then
                        printf '  SHARED (!) %s -> %s\n' "$_cp_j" "$(readlink "$_cp_j")"
                    else
                        printf '  isolated   %s\n' "$_cp_j"
                    fi
                done
            )
            # Say so when there was nothing to inspect, rather than printing an
            # empty section a reader could mistake for a passed check.
            if [ -n "$_cp_iso" ]; then
                printf '%s\n' "$_cp_iso"
            else
                printf '  nothing to inspect (no ~/.claude.json and no profiles yet)\n'
            fi
            case "$_cp_iso" in *'SHARED (!)'*) _cp_rc=1 ;; esac

            # The same question for Codex. config.toml is where its MCP server
            # definitions and `env_key` live, and auth.json is the credential
            # store outright — neither may ever be a link to a shared copy.
            printf '\nCodex credential and MCP isolation:\n'
            _cp_iso=$(
                {
                    for _cp_j in "$HOME/.codex/config.toml" "$HOME/.codex/auth.json"; do
                        [ -f "$_cp_j" ] && printf '%s\n' "$_cp_j"
                    done
                    [ -d "$(_codex_profile_root)" ] &&
                        find "$(_codex_profile_root)" -mindepth 2 -maxdepth 2 \
                            \( -name 'config.toml' -o -name 'auth.json' \) 2>/dev/null | sort
                } | while IFS= read -r _cp_j; do
                    [ -f "$_cp_j" ] || continue
                    if [ -L "$_cp_j" ]; then
                        printf '  SHARED (!) %s -> %s\n' "$_cp_j" "$(readlink "$_cp_j")"
                    else
                        printf '  isolated   %s\n' "$_cp_j"
                    fi
                done
            )
            if [ -n "$_cp_iso" ]; then
                printf '%s\n' "$_cp_iso"
            else
                printf '  no Codex profiles yet\n'
            fi
            case "$_cp_iso" in *'SHARED (!)'*) _cp_rc=1 ;; esac
            unset _cp_found _cp_iso _cp_j
            return $_cp_rc
            ;;

        spend)
            # What has each profile used this month, priced at Claude API
            # list rates? Claude Code writes a JSONL transcript per session
            # under <config dir>/projects/, and every assistant message in it
            # carries the model and exact token counts — so the transcripts
            # already are the ledger, and no extra state is ever kept.
            #
            # Subscription plans are not billed per token; the figure is the
            # pay-as-you-go equivalent, which is still the honest way to
            # compare profiles (and months) against each other.
            if ! command -v python3 >/dev/null 2>&1; then
                printf 'claude-profile: spend needs python3 to read the session transcripts.\n' >&2
                return 1
            fi
            _cp_pairs=$(printf '(default)\t%s' "$HOME/.claude/projects")
            if [ -d "$CLAUDE_PROFILES_DIR" ]; then
                _cp_more=$(find "$CLAUDE_PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
                    sort | while IFS= read -r _cp_d; do
                    _cp_n=$(basename "$_cp_d")
                    _claude_profile_exists "$_cp_n" || continue
                    printf -- '-%s\t%s\n' "$_cp_n" "$_cp_d/projects"
                done)
                [ -n "$_cp_more" ] && _cp_pairs="$_cp_pairs
$_cp_more"
                unset _cp_more
            fi
            CLAUDE_PROFILE_SPEND_DIRS="$_cp_pairs" python3 - "$@" <<'PYEOF'
import json
import os
import sys
from datetime import datetime

def die(msg):
    sys.stderr.write("claude-profile: %s\n" % msg)
    sys.exit(1)

month = None
as_json = False
by_model = False
for arg in sys.argv[1:]:
    if arg == "--json":
        as_json = True
    elif arg in ("--models", "-m"):
        by_model = True
    elif (len(arg) == 7 and arg[4] == "-"
          and arg[:4].isdigit() and arg[5:].isdigit() and 1 <= int(arg[5:]) <= 12):
        month = arg
    else:
        die("spend: unrecognised argument %r (expected YYYY-MM, --models or --json)" % arg)
if month is None:
    month = datetime.now().astimezone().strftime("%Y-%m")

# USD per million tokens: (id fragment, input, output). First match wins, so
# specific generations sit above their family fallback. Cache pricing hangs
# off the input rate everywhere: 5-minute writes at 1.25x, 1-hour writes at
# 2x, reads at 0.1x. Prices move rarely, but they do move — the list-price
# table at https://platform.claude.com/docs/en/pricing is the reference.
PRICES = (
    ("fable-5", 10.0, 50.0),
    ("mythos", 10.0, 50.0),
    ("opus-4-1", 15.0, 75.0),
    ("opus-4-0", 15.0, 75.0),
    ("opus-4-2025", 15.0, 75.0),
    ("3-opus", 15.0, 75.0),
    ("opus", 5.0, 25.0),
    ("sonnet", 3.0, 15.0),
    ("3-5-haiku", 0.8, 4.0),
    ("3-haiku", 0.25, 1.25),
    ("haiku", 1.0, 5.0),
)

def rates(model):
    for fragment, per_in, per_out in PRICES:
        if fragment in model:
            return per_in, per_out
    return None

def new_agg():
    return {"msgs": 0, "input": 0, "output": 0,
            "cache_w": 0, "cache_r": 0, "cost": 0.0}

def bump(agg, tin, tout, c5m, c1h, crd, cost):
    agg["msgs"] += 1
    agg["input"] += tin
    agg["output"] += tout
    agg["cache_w"] += c5m + c1h
    agg["cache_r"] += crd
    agg["cost"] += cost

profiles = []          # insertion order
totals = {}            # profile -> aggregate
model_totals = {}      # (profile, model) -> aggregate
unpriced = set()
seen = set()           # (message id, request id) — resumed sessions copy
                       # their history into a fresh transcript, so the same
                       # billed message can appear in several files.

for pair in os.environ.get("CLAUDE_PROFILE_SPEND_DIRS", "").splitlines():
    if "\t" not in pair:
        continue
    name, root = pair.split("\t", 1)
    profiles.append(name)
    totals[name] = new_agg()
    if not os.path.isdir(root):
        continue
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(".jsonl"):
                continue
            try:
                fh = open(os.path.join(dirpath, fn), encoding="utf-8",
                          errors="replace")
            except OSError:
                continue
            with fh:
                for line in fh:
                    # Cheap pre-filter: only assistant messages carry usage,
                    # and most lines in a transcript are something else.
                    if '"usage"' not in line or '"assistant"' not in line:
                        continue
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if entry.get("type") != "assistant":
                        continue
                    msg = entry.get("message")
                    if not isinstance(msg, dict):
                        continue
                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    model = msg.get("model") or ""
                    # "<synthetic>" marks locally generated filler, not a
                    # billed API response.
                    if not model or model.startswith("<"):
                        continue
                    ts = entry.get("timestamp") or ""
                    try:
                        stamp = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except ValueError:
                        continue
                    if stamp.astimezone().strftime("%Y-%m") != month:
                        continue
                    key = (msg.get("id"), entry.get("requestId"))
                    if key[0] is not None:
                        if key in seen:
                            continue
                        seen.add(key)
                    tin = usage.get("input_tokens") or 0
                    tout = usage.get("output_tokens") or 0
                    crd = usage.get("cache_read_input_tokens") or 0
                    creation = usage.get("cache_creation")
                    if isinstance(creation, dict):
                        c5m = creation.get("ephemeral_5m_input_tokens") or 0
                        c1h = creation.get("ephemeral_1h_input_tokens") or 0
                    else:
                        c5m = usage.get("cache_creation_input_tokens") or 0
                        c1h = 0
                    r = rates(model)
                    if r is None:
                        unpriced.add(model)
                        cost = 0.0
                    else:
                        per_in, per_out = r
                        cost = (tin * per_in + tout * per_out
                                + c5m * per_in * 1.25 + c1h * per_in * 2.0
                                + crd * per_in * 0.1) / 1_000_000
                    bump(totals[name], tin, tout, c5m, c1h, crd, cost)
                    agg = model_totals.setdefault((name, model), new_agg())
                    bump(agg, tin, tout, c5m, c1h, crd, cost)

grand = sum(agg["cost"] for agg in totals.values())

if as_json:
    out = {"month": month, "total_usd": round(grand, 2), "profiles": []}
    for name in profiles:
        agg = totals[name]
        out["profiles"].append({
            "name": name,
            "messages": agg["msgs"],
            "input_tokens": agg["input"],
            "output_tokens": agg["output"],
            "cache_write_tokens": agg["cache_w"],
            "cache_read_tokens": agg["cache_r"],
            "spend_usd": round(agg["cost"], 2),
            "models": {m: round(a["cost"], 2)
                       for (p, m), a in sorted(model_totals.items())
                       if p == name},
        })
    if unpriced:
        out["unpriced_models"] = sorted(unpriced)
    print(json.dumps(out, indent=2))
    sys.exit(0)

def htok(n):
    for div, suffix in ((10**9, "B"), (10**6, "M"), (10**3, "K")):
        if n >= div:
            return "%.1f%s" % (n / div, suffix)
    return str(n)

ROW = "%-20s %6s %9s %9s %9s %9s %11s"
print("Spend for %s, priced at Claude API list rates" % month)
print()
print(ROW % ("PROFILE", "MSGS", "INPUT", "OUTPUT", "CACHE WR", "CACHE RD", "SPEND"))
for name in profiles:
    agg = totals[name]
    print(ROW % (name, agg["msgs"], htok(agg["input"]), htok(agg["output"]),
                 htok(agg["cache_w"]), htok(agg["cache_r"]),
                 "$%.2f" % agg["cost"]))
    if by_model:
        for (p, m), a in sorted(model_totals.items()):
            if p == name:
                print(ROW % ("  " + m, a["msgs"], htok(a["input"]),
                             htok(a["output"]), htok(a["cache_w"]),
                             htok(a["cache_r"]), "$%.2f" % a["cost"]))
print(ROW % ("TOTAL", "", "", "", "", "", "$%.2f" % grand))
print()
print("Subscription plans are not billed per token; this is what the usage")
print("would cost at pay-as-you-go API list rates.")
if unpriced:
    print()
    print("Unrecognised models counted but priced at $0:")
    for m in sorted(unpriced):
        print("  " + m)
PYEOF
            _cp_rc=$?

            # Codex usage, reported separately and in tokens only.
            #
            # No dollar figure: the models these sessions actually run on have
            # no list-price table in this script, and inventing one would put a
            # confidently wrong number next to a correct one. Tokens are the
            # part that can be stated honestly, so that is what is stated.
            _cp_pairs=$(printf '(default)\t%s' "$HOME/.codex/sessions")
            if [ -d "$(_codex_profile_root)" ]; then
                _cp_more=$(find "$(_codex_profile_root)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
                    sort | while IFS= read -r _cp_d; do
                    _cp_n=$(basename "$_cp_d")
                    _codex_profile_exists "$_cp_n" || continue
                    printf -- '-%s\t%s\n' "$_cp_n" "$_cp_d/sessions"
                done)
                [ -n "$_cp_more" ] && _cp_pairs="$_cp_pairs
$_cp_more"
                unset _cp_more
            fi
            if command -v codex >/dev/null 2>&1; then
                printf '\n'
                CODEX_PROFILE_SPEND_DIRS="$_cp_pairs" python3 - "$@" <<'CODEXSPENDEOF'
import json
import os
import sys
from datetime import datetime

month = None
as_json = False
for arg in sys.argv[1:]:
    if arg == "--json":
        as_json = True
    elif arg in ("--models", "-m"):
        pass
    elif (len(arg) == 7 and arg[4] == "-"
          and arg[:4].isdigit() and arg[5:].isdigit() and 1 <= int(arg[5:]) <= 12):
        month = arg
if month is None:
    month = datetime.now().astimezone().strftime("%Y-%m")

pairs = []
for line in os.environ.get("CODEX_PROFILE_SPEND_DIRS", "").splitlines():
    if "\t" in line:
        label, path = line.split("\t", 1)
        pairs.append((label, path))

# Codex writes a JSONL rollout per session. Its `token_count` events carry
# `total_token_usage`, a counter that only ever climbs across the session, and
# `last_token_usage` for the turn. The cumulative counter is the one used here:
# summing the per-turn figures overcounts by 2-5% because Codex emits more
# than one event for some turns, and it was never short in any session
# examined. Taking the cumulative value at the end of the month minus its
# value before the month starts also attributes a session that straddles a
# month boundary to the right months, instead of dumping all of it in one.
def totals_for(root):
    msgs = 0
    used = {"input": 0, "output": 0, "cached": 0}
    models = {}
    if not os.path.isdir(root):
        return msgs, used, models
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(".jsonl"):
                continue
            before = None
            within = None
            turns = 0
            model = None
            last_model_in_month = None
            try:
                fh = open(os.path.join(dirpath, fn), errors="ignore")
            except OSError:
                continue
            with fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    payload = rec.get("payload") or {}
                    if rec.get("type") == "turn_context":
                        model = payload.get("model") or model
                    if rec.get("type") != "event_msg":
                        continue
                    if payload.get("type") != "token_count":
                        continue
                    info = payload.get("info") or {}
                    tu = info.get("total_token_usage")
                    if not isinstance(tu, dict):
                        continue
                    stamp = rec.get("timestamp") or ""
                    snapshot = (tu.get("input_tokens", 0),
                                tu.get("output_tokens", 0),
                                tu.get("cached_input_tokens", 0))
                    if stamp[:7] < month:
                        before = snapshot
                    elif stamp[:7] == month:
                        within = snapshot
                        turns += 1
                        last_model_in_month = model
            if within is None:
                continue
            base = before or (0, 0, 0)
            delta = [max(0, w - b) for w, b in zip(within, base)]
            if not any(delta):
                continue
            msgs += turns
            used["input"] += delta[0]
            used["output"] += delta[1]
            used["cached"] += delta[2]
            key = last_model_in_month or "unknown"
            agg = models.setdefault(key, {"input": 0, "output": 0, "cached": 0})
            agg["input"] += delta[0]
            agg["output"] += delta[1]
            agg["cached"] += delta[2]
    return msgs, used, models

rows = []
for label, path in pairs:
    msgs, used, models = totals_for(path)
    rows.append((label, msgs, used, models))

if not any(r[1] or any(r[2].values()) for r in rows):
    sys.exit(0)

if as_json:
    print(json.dumps({
        "month": month,
        "runtime": "codex",
        "priced": False,
        "profiles": [
            {"profile": label, "turns": msgs,
             "input_tokens": used["input"], "output_tokens": used["output"],
             "cached_input_tokens": used["cached"],
             "models": sorted(models)}
            for label, msgs, used, models in rows
        ],
    }, indent=2))
    sys.exit(0)

def htok(n):
    for div, suffix in ((10**9, "B"), (10**6, "M"), (10**3, "K")):
        if n >= div:
            return "%.1f%s" % (n / div, suffix)
    return str(n)

ROW = "%-20s %6s %9s %9s %9s"
print("Codex usage for %s, tokens only" % month)
print()
print(ROW % ("PROFILE", "TURNS", "INPUT", "OUTPUT", "OF WHICH"))
print(ROW % ("", "", "", "", "CACHED"))
for label, msgs, used, models in rows:
    print(ROW % (label, msgs, htok(used["input"]), htok(used["output"]),
                 htok(used["cached"])))
    for name in sorted(models):
        agg = models[name]
        print(ROW % ("  " + name, "", htok(agg["input"]), htok(agg["output"]),
                     htok(agg["cached"])))
print()
print("INPUT already includes the cached tokens, so those two columns do not")
print("add up - Codex reports total_tokens as input + output alone.")
print()
print("Not priced: this script has no list-price table for these models, and")
print("a guessed rate next to a real one is worse than no rate at all.")
CODEXSPENDEOF
            fi
            unset _cp_pairs _cp_d _cp_n
            return $_cp_rc
            ;;

        doctor)
            _cp_rc=0
            printf 'claude-profiles doctor\n\n'

            printf 'Launcher:\n'
            if command -v claude >/dev/null 2>&1; then
                printf '  claude binary: %s\n' "$(_claude_profile_bin)"
            else
                printf '  FAIL claude is not on PATH\n'
                _cp_rc=1
            fi
            # The wrapper is a shell function; anything sourced after us that
            # also defines `claude` wins, and an update to Claude Code is a
            # common way for that to happen without anyone noticing.
            if [ -n "$ZSH_VERSION" ]; then
                _cp_kind=$(whence -w claude 2>/dev/null | awk '{print $2}')
            else
                _cp_kind=$(type -t claude 2>/dev/null)
            fi
            case "$_cp_kind" in
                function) printf '  wrapper active (shell function)\n' ;;
                *)
                    printf '  FAIL claude is "%s", not the claude-profiles function.\n' "${_cp_kind:-unknown}"
                    printf '       Something redefined it after we were sourced;\n'
                    printf '       claude -<name> will not switch profiles.\n'
                    _cp_rc=1
                    ;;
            esac

            # Codex is optional: not having it installed is not a failure, but
            # having it installed with the wrapper shadowed is.
            if command -v codex >/dev/null 2>&1; then
                printf '  codex binary:  %s\n' "$(_codex_profile_bin)"
                if [ -n "$ZSH_VERSION" ]; then
                    _cp_kind=$(whence -w codex 2>/dev/null | awk '{print $2}')
                else
                    _cp_kind=$(type -t codex 2>/dev/null)
                fi
                case "$_cp_kind" in
                    function) printf '  codex wrapper active (shell function)\n' ;;
                    *)
                        printf '  FAIL codex is "%s", not the claude-profiles function.\n' "${_cp_kind:-unknown}"
                        printf '       codex -<name> will not switch profiles.\n'
                        _cp_rc=1
                        ;;
                esac
            else
                printf '  codex binary:  not installed (Codex profiles unavailable)\n'
            fi

            printf '\nRunning Claude processes:\n'
            _cp_stale=$(_claude_profile_stale_processes)
            _cp_stale_rc=$?
            if [ "$_cp_stale_rc" -eq 2 ]; then
                printf '  SKIP — process inspection needs id, pgrep and lsof\n'
            elif [ -n "$_cp_stale" ]; then
                _cp_stale_count=$(printf '%s\n' "$_cp_stale" | wc -l | tr -d ' ')
                printf '  WARN %s session(s) are running from executables no longer on disk:\n' \
                    "$_cp_stale_count"
                printf '%s\n' "$_cp_stale" | while IFS='|' read -r _cp_pid _cp_exe; do
                    printf '    pid %s: %s\n' "$_cp_pid" "$_cp_exe"
                done
                printf '       This can leave stale runtime state after an upgrade. Save work,\n'
                printf '       exit those sessions normally, then retry the profile launch.\n'
                _cp_rc=1
            else
                printf '  ok — no sessions running from removed executables\n'
            fi

            printf '\nCLAUDE_CONFIG_DIR still honoured:\n'
            # `claude --version` never touches the config dir, so asking it to
            # run against a throwaway dir proves nothing. Start a real session
            # against a scratch dir instead and check the dir gets populated
            # while ~/.claude is left alone. That is the check that catches an
            # update quietly changing the mechanism.
            _cp_probe=$(mktemp -d 2>/dev/null) || _cp_probe=""
            if [ -n "$_cp_probe" ] && command -v claude >/dev/null 2>&1; then
                CLAUDE_CONFIG_DIR="$_cp_probe" command claude -p 'ok' >/dev/null 2>&1
                if [ -n "$(ls -A "$_cp_probe" 2>/dev/null)" ]; then
                    printf '  ok — probe config dir was populated\n'
                else
                    printf '  WARN probe dir stayed empty. Either the probe could not\n'
                    printf '       reach the API, or CLAUDE_CONFIG_DIR is being ignored.\n'
                    printf '       Re-check by hand before trusting profile isolation.\n'
                    _cp_rc=1
                fi
                rm -rf "$_cp_probe"
            else
                printf '  SKIP could not create a probe directory\n'
            fi

            # Codex's equivalent probe, and a cheaper one: `codex login
            # status` against an empty home reports "Not logged in" without
            # touching the network. If CODEX_HOME were being ignored it would
            # instead report the default home's real account.
            if command -v codex >/dev/null 2>&1; then
                printf '\nCODEX_HOME still honoured:\n'
                _cp_probe="${TMPDIR:-/tmp}/claude-profiles-codex-probe.$$"
                if mkdir -p "$_cp_probe" 2>/dev/null; then
                    _cp_out=$(CODEX_HOME="$_cp_probe" command codex login status 2>&1)
                    case "$_cp_out" in
                        *'Not logged in'*)
                            printf '  yes — an empty CODEX_HOME reports no credentials\n'
                            ;;
                        *)
                            printf '  FAIL an empty CODEX_HOME still reported: %s\n' "$_cp_out"
                            printf '       Codex may be ignoring CODEX_HOME, in which case\n'
                            printf '       codex -<name> is billing the default account.\n'
                            _cp_rc=1
                            ;;
                    esac
                    rm -rf "$_cp_probe"
                else
                    printf '  SKIP could not create a probe directory\n'
                fi
                unset _cp_probe _cp_out
            fi

            printf '\nStatus line:\n'
            if [ -x "$CLAUDE_PROFILE_STATUS_BIN" ]; then
                printf '  renderer present: %s\n' "$CLAUDE_PROFILE_STATUS_BIN"
            else
                printf '  FAIL renderer missing or not executable: %s\n' "$CLAUDE_PROFILE_STATUS_BIN"
                _cp_rc=1
            fi
            if grep -q '"statusLine"' "$HOME/.claude/settings.json" 2>/dev/null; then
                printf '  wired into shared settings.json\n'
            else
                printf '  FAIL no statusLine in ~/.claude/settings.json — sessions will\n'
                printf '       not show which profile they are billing.\n'
                printf '       Run: claude-profile repair --all\n'
                _cp_rc=1
            fi

            printf '\nProfiles:\n'
            # Collect into a variable rather than setting _cp_rc inside the
            # loop: the `|` puts the loop body in a subshell in most shells,
            # so an assignment made in there would not survive.
            _cp_issues=""
            # The emptiness test matters as much as the existence one: under
            # zsh `for x in dir/*` is a hard error when the glob matches
            # nothing, so a fresh install with no profiles would abort here.
            if [ -d "$CLAUDE_PROFILES_DIR" ] &&
                [ -n "$(find "$CLAUDE_PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null)" ]; then
                for _cp_d in "$CLAUDE_PROFILES_DIR"/*; do
                    [ -d "$_cp_d" ] || continue
                    _cp_n=$(basename "$_cp_d")
                    _claude_profile_exists "$_cp_n" || continue
                    printf '  %s\n' "$_cp_n"
                    _cp_p=$(_claude_profile_shared_items | while IFS= read -r _cp_item; do
                        [ -e "$HOME/.claude/$_cp_item" ] || continue
                        if [ -L "$_cp_d/$_cp_item" ]; then
                            [ -e "$_cp_d/$_cp_item" ] ||
                                printf 'DANGLING %s\n' "$_cp_item"
                        elif [ -e "$_cp_d/$_cp_item" ]; then
                            # Exactly what an atomic temp-file-plus-rename
                            # settings write leaves behind: the profile
                            # stopped sharing and nothing said so.
                            printf 'UNSHARED %s is a real file, no longer linked\n' "$_cp_item"
                        else
                            printf 'MISSING  %s\n' "$_cp_item"
                        fi
                    done)
                    if [ -n "$_cp_p" ]; then
                        printf '%s\n' "$_cp_p" | sed 's/^/    /'
                        _cp_issues="yes"
                    else
                        printf '    shared config intact\n'
                    fi
                    if _codex_profile_exists "$_cp_n"; then
                        printf '    codex: %s\n' \
                            "$(_codex_profile_account "$(_codex_profile_root)/$_cp_n")"
                    fi
                done
            fi

            # A Codex home with no matching Claude profile is legitimate, but
            # it would otherwise go unlisted here entirely.
            if [ -d "$(_codex_profile_root)" ] &&
                [ -n "$(find "$(_codex_profile_root)" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null)" ]; then
                for _cp_d in "$(_codex_profile_root)"/*; do
                    [ -d "$_cp_d" ] || continue
                    _cp_n=$(basename "$_cp_d")
                    _codex_profile_exists "$_cp_n" || continue
                    _claude_profile_exists "$_cp_n" && continue
                    printf '  %s (codex only)\n' "$_cp_n"
                    printf '    codex: %s\n' "$(_codex_profile_account "$_cp_d")"
                done
            fi
            if [ -n "$_cp_issues" ]; then
                printf '\n  Fix with: claude-profile repair --all\n'
                _cp_rc=1
            fi

            printf '\n'
            if [ "$_cp_rc" -eq 0 ]; then
                printf 'No blocking problems found.\n'
            else
                printf 'Problems found — see FAIL/WARN above.\n'
            fi
            unset _cp_probe _cp_kind _cp_d _cp_n _cp_item _cp_stale
            unset _cp_stale_rc _cp_stale_count _cp_uid _cp_pid _cp_exe
            return $_cp_rc
            ;;

        repair)
            _cp_target="${1:---all}"
            _cp_rc_status=0
            printf 'Repairing shared config.\n\n'

            # 1. The status line, in the shared settings file so one entry
            #    serves every profile.
            if [ ! -f "$HOME/.claude/settings.json" ]; then
                printf '{}\n' > "$HOME/.claude/settings.json"
            fi
            if grep -q '"statusLine"' "$HOME/.claude/settings.json" 2>/dev/null; then
                printf 'statusLine already present in ~/.claude/settings.json\n'
            elif [ ! -x "$CLAUDE_PROFILE_STATUS_BIN" ]; then
                # Wiring a command that does not exist would kill every
                # session's status line silently — the profile label is the
                # safety feature, so refuse loudly instead.
                printf 'WARNING: NOT wiring statusLine: renderer missing or not executable:\n' >&2
                printf '  %s\n' "$CLAUDE_PROFILE_STATUS_BIN" >&2
                printf 'Run install.sh, or set CLAUDE_PROFILE_STATUS_BIN to the path of\n' >&2
                printf 'bin/profile-status.sh before sourcing, then run repair again.\n' >&2
                _cp_rc_status=1
            else
                _cp_bak="$HOME/.claude/settings.json.bak-$(date +%Y%m%d%H%M%S)"
                cp "$HOME/.claude/settings.json" "$_cp_bak" 2>/dev/null
                _cp_ok=""
                if command -v python3 >/dev/null 2>&1; then
                    if python3 - "$HOME/.claude/settings.json" "$CLAUDE_PROFILE_STATUS_BIN" <<'PYEOF'
import json, sys
path, binpath = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
data["statusLine"] = {"type": "command", "command": binpath}
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PYEOF
                    then
                        _cp_ok=yes
                        printf 'Added statusLine to ~/.claude/settings.json (backup: %s)\n' "$_cp_bak"
                    fi
                fi
                if [ -z "$_cp_ok" ]; then
                    printf 'Could not edit ~/.claude/settings.json automatically.\n'
                    printf 'Add this by hand, or sessions will not show their profile:\n'
                    printf '  "statusLine": { "type": "command", "command": "%s" }\n' \
                        "$CLAUDE_PROFILE_STATUS_BIN"
                fi
            fi

            # 2. Shared links, per profile. Never destroys a divergent copy.
            printf '\n'
            if [ ! -d "$CLAUDE_PROFILES_DIR" ] ||
                [ -z "$(find "$CLAUDE_PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null)" ]; then
                printf 'No profiles yet.\n'
                unset _cp_target _cp_bak
                return $_cp_rc_status
            fi
            for _cp_d in "$CLAUDE_PROFILES_DIR"/*; do
                [ -d "$_cp_d" ] || continue
                _cp_n=$(basename "$_cp_d")
                _claude_profile_exists "$_cp_n" || continue
                case "$_cp_target" in
                    --all | "$_cp_n") ;;
                    *) continue ;;
                esac
                printf '%s:\n' "$_cp_n"
                _cp_did=$(
                    _claude_profile_shared_items | while IFS= read -r _cp_item; do
                        _claude_profile_link_item "$_cp_d" "$_cp_item"
                    done
                    if [ -d "$(_codex_profile_root)/$_cp_n" ]; then
                        _claude_profile_shared_items "$CODEX_PROFILE_SHARED" |
                            while IFS= read -r _cp_item; do
                                _claude_profile_link_item \
                                    "$(_codex_profile_root)/$_cp_n" "$_cp_item" "$HOME/.codex"
                            done
                    fi
                )
                if [ -n "$_cp_did" ]; then
                    printf '%s\n' "$_cp_did" | sed 's/^/  /'
                else
                    printf '  already correct\n'
                fi
            done
            unset _cp_target _cp_d _cp_n _cp_did _cp_bak
            return $_cp_rc_status
            ;;

        path)
            # path <name> [claude|codex] — defaults to claude, which is what
            # every existing script calling this expects.
            case "${2:-claude}" in
                claude) _cp_dir=$(_claude_profile_dir "$1") ;;
                codex) _cp_dir=$(_codex_profile_home "$1") ;;
                *)
                    printf 'claude-profile: unknown runtime "%s" (want claude or codex)\n' "$2" >&2
                    return 1
                    ;;
            esac
            if [ -z "$_cp_dir" ]; then
                printf 'claude-profile: invalid profile name\n' >&2
                return 1
            fi
            printf '%s\n' "$_cp_dir"
            unset _cp_dir
            ;;

        help | -h | --help)
            claude_profile_usage
            ;;

        *)
            printf 'claude-profile: unknown command: %s\n\n' "$_cp_cmd" >&2
            claude_profile_usage >&2
            return 1
            ;;
    esac
    unset _cp_cmd
}

# --- completion --------------------------------------------------------------

# Completion candidates. This filters on _claude_profile_valid_name as well as
# the reserved-directory list, because the profiles directory now also holds
# the hidden ".codex" tree — and a name starting with a dot is exactly what
# that validator rejects. Without it, completion would offer "-.codex".
_claude_profiles_names() {
    [ -d "$CLAUDE_PROFILES_DIR" ] || return 0
    find "$CLAUDE_PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
        while IFS= read -r _cp_d; do
            _cp_b=$(basename "$_cp_d")
            _claude_profile_valid_name "$_cp_b" || continue
            _claude_profile_is_reserved_dir "$_cp_b" || printf '%s\n' "$_cp_b"
        done
}

# The same candidates, for `codex -<name>`.
_codex_profiles_names() {
    [ -d "$(_codex_profile_root)" ] || return 0
    find "$(_codex_profile_root)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
        while IFS= read -r _cp_d; do
            _cp_b=$(basename "$_cp_d")
            _claude_profile_valid_name "$_cp_b" || continue
            _claude_profile_is_reserved_dir "$_cp_b" || printf '%s\n' "$_cp_b"
        done
}

if [ -n "$ZSH_VERSION" ]; then
    _claude_profiles_complete() {
        local -a names
        names=(${(f)"$(_claude_profiles_names)"})
        [ ${#names} -eq 0 ] && return 1
        compadd -P '-' -- $names
    }
    _codex_profiles_complete() {
        local -a names
        names=(${(f)"$(_codex_profiles_names)"})
        [ ${#names} -eq 0 ] && return 1
        compadd -P '-' -- $names
    }
    # compdef only exists once compinit has run; ignore failure if it hasn't.
    if whence compdef >/dev/null 2>&1; then
        compdef _claude_profiles_complete claude 2>/dev/null
        compdef _codex_profiles_complete codex 2>/dev/null
    fi
elif [ -n "$BASH_VERSION" ]; then
    _claude_profiles_complete_bash() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        if [ "$COMP_CWORD" -eq 1 ] && [ "${cur#-}" != "$cur" ]; then
            local names
            names=$(_claude_profiles_names)
            # Word splitting is intended here; profile names cannot contain
            # whitespace (see _claude_profile_valid_name).
            # shellcheck disable=SC2207
            COMPREPLY=($(compgen -P '-' -W "$names" -- "${cur#-}"))
        fi
    }
    _codex_profiles_complete_bash() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        if [ "$COMP_CWORD" -eq 1 ] && [ "${cur#-}" != "$cur" ]; then
            local names
            names=$(_codex_profiles_names)
            # Word splitting is intended here; profile names cannot contain
            # whitespace (see _claude_profile_valid_name).
            # shellcheck disable=SC2207
            COMPREPLY=($(compgen -P '-' -W "$names" -- "${cur#-}"))
        fi
    }
    complete -F _claude_profiles_complete_bash claude 2>/dev/null
    complete -F _codex_profiles_complete_bash codex 2>/dev/null
fi
