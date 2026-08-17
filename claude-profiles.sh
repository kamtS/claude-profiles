#!/usr/bin/env bash
# claude-profiles — multiple Claude Code workspace logins, one CLI
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
#     claude-profile new work create a profile and log into it
#     claude-profile ls       list profiles and their accounts
#     claude-profile rm work  delete a profile
#
# How it works: Claude Code reads CLAUDE_CONFIG_DIR to decide where its
# config, credentials, MCP servers and history live. This wrapper swaps
# that directory based on a leading -<name> argument. On macOS the OS
# keychain namespaces credentials per config dir, so logins never collide.
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
CLAUDE_PROFILE_SHARED="settings.json skills agents commands plugins CLAUDE.md"

# Where the statusLine renderer lives, relative to this script.
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
_claude_profile_is_real_flag() {
    case "$1" in
        -c | -d | -h | -n | -p | -r | -v | -w) return 0 ;;
    esac
    command -v claude >/dev/null 2>&1 || return 1
    command claude --help 2>/dev/null |
        grep -qE "(^|[[:space:],])$(printf '%s' "$1" | sed 's/[^A-Za-z0-9-]/./g')([[:space:],]|$)"
}

# Emit the shared-config entries, one per line.
# Iterate via `tr` + `read`, NOT `for x in $CLAUDE_PROFILE_SHARED`: zsh does not
# word-split unquoted scalars, so a plain `for` loop silently iterated nothing.
_claude_profile_shared_items() {
    printf '%s\n' "$CLAUDE_PROFILE_SHARED" | tr ' ' '\n' | while IFS= read -r _cp_i; do
        [ -n "$_cp_i" ] && printf '%s\n' "$_cp_i"
    done
}

# Link one shared entry into a profile. Reports what it did on stdout so the
# caller can summarise. Never clobbers an existing entry.
_claude_profile_link_item() {
    _cp_t="$HOME/.claude/$2"
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

claude() {
    _cp_dir=""

    # Claim a leading single-dash argument when it names an existing profile.
    # When it does not, the old behaviour was to pass it through to Claude Code
    # unchanged — which meant `claude -clienta` after a rename, a moved
    # CLAUDE_PROFILES_DIR, or a plain typo ran the DEFAULT profile without a
    # word. For anyone billing clients per profile that is the worst possible
    # failure: silent, and wrong in the expensive direction. So an unmatched
    # profile-shaped argument is now a hard error, and only arguments that are
    # genuinely Claude Code flags pass through.
    case "$1" in
        --* | "") ;;
        -?*)
            _cp_name="${1#-}"
            if _claude_profile_valid_name "$_cp_name"; then
                if _claude_profile_exists "$_cp_name"; then
                    _cp_dir="$CLAUDE_PROFILES_DIR/$_cp_name"
                    shift
                elif ! _claude_profile_is_real_flag "$1"; then
                    printf 'claude-profile: no profile "%s" in %s\n' \
                        "$_cp_name" "$CLAUDE_PROFILES_DIR" >&2
                    printf 'Refusing to fall back to the default profile.\n' >&2
                    printf 'Run "claude-profile ls" to see what exists.\n' >&2
                    unset _cp_name _cp_dir
                    return 2
                fi
            fi
            unset _cp_name
            ;;
    esac

    if [ -n "$_cp_dir" ]; then
        # CLAUDE_PROFILE is exported for anything downstream that wants to show
        # the profile too — a shell prompt, tmux, a hook.
        [ -n "${CLAUDE_PROFILE_QUIET:-}" ] ||
            printf 'claude-profiles: %s → %s\n' "$(basename "$_cp_dir")" "$_cp_dir" >&2
        CLAUDE_CONFIG_DIR="$_cp_dir" CLAUDE_PROFILE="$(basename "$_cp_dir")" \
            command claude "$@"
    else
        unset _cp_dir
        command claude "$@"
    fi
}

# --- the manager -------------------------------------------------------------

claude_profile_usage() {
    cat <<'EOF'
claude-profile — manage Claude Code workspace profiles

  claude-profile new <name>    create a profile, then log into it
  claude-profile ls            list profiles and the account each holds
  claude-profile rm <name>     delete a profile
  claude-profile path <name>   print a profile's config directory
  claude-profile exec <name> [--] <cmd...>
                               run a command against a profile, for scripts
  claude-profile audit [name]  check shared config for credentials
  claude-profile doctor        check the install still works after an update
  claude-profile repair [name|--all]
                               restore shared links and the status line

Once created, run Claude Code against a profile by prefixing its name:

  claude -<name> [args...]

That prefix works only in an interactive shell, because it is a shell
function. In scripts, cron jobs and CI — where ~/.zshrc is never sourced —
use `claude-profile exec <name> -- claude -p '...'` instead. Calling
`claude` directly there silently uses the DEFAULT profile.

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

            # Make sure the session will say which profile it is billing.
            if ! grep -q '"statusLine"' "$HOME/.claude/settings.json" 2>/dev/null; then
                printf '\nNote: no statusLine configured, so sessions will not display\n'
                printf 'which profile they are running as. Run: claude-profile repair\n'
            fi
            printf '\nStarting Claude Code in this profile so you can log in.\n'
            printf 'If it does not prompt automatically, run /login.\n\n'
            CLAUDE_CONFIG_DIR="$_cp_dir" command claude
            printf '\nDone. Use this profile any time with: claude -%s\n' "$_cp_name"
            unset _cp_name _cp_dir _cp_item
            ;;

        ls | list)
            printf '%-16s %s\n' "PROFILE" "ACCOUNT"
            # The default profile keeps its config JSON at ~/.claude.json,
            # not inside ~/.claude/.
            printf '%-16s %s\n' "(default)" "$(_claude_profile_account "$HOME/.claude.json")"

            if [ -d "$CLAUDE_PROFILES_DIR" ]; then
                # find, not a glob: portable across bash and zsh, and safe
                # when the directory is empty.
                find "$CLAUDE_PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
                    sort | while IFS= read -r _cp_d; do
                    _cp_n=$(basename "$_cp_d")
                    _claude_profile_exists "$_cp_n" || continue
                    printf '%-16s %s\n' "-$_cp_n" "$(_claude_profile_account "$_cp_d/.claude.json")"
                done
            fi
            ;;

        rm | remove | delete)
            _cp_name="$1"
            if ! _claude_profile_valid_name "$_cp_name"; then
                printf 'claude-profile: invalid profile name: %s\n' "${_cp_name:-<empty>}" >&2
                return 1
            fi
            _cp_dir="$CLAUDE_PROFILES_DIR/$_cp_name"

            # Belt and braces: the name is already validated, but confirm the
            # target really is a direct child of the profiles directory and
            # not a symlink pointing somewhere else before removing anything.
            if [ -L "$_cp_dir" ]; then
                printf 'claude-profile: "%s" is a symlink; refusing to delete.\n' "$_cp_name" >&2
                return 1
            fi
            if [ ! -d "$_cp_dir" ]; then
                printf 'claude-profile: no such profile: %s\n' "$_cp_name" >&2
                return 1
            fi
            case "$_cp_dir" in
                "$CLAUDE_PROFILES_DIR"/*) ;;
                *)
                    printf 'claude-profile: refusing to delete outside %s\n' "$CLAUDE_PROFILES_DIR" >&2
                    return 1
                    ;;
            esac

            printf 'Delete profile "%s" (%s)?\n' "$_cp_name" "$_cp_dir"
            printf 'Its login, history and MCP auth will be removed. Type the name to confirm: '
            read -r _cp_reply
            if [ "$_cp_reply" != "$_cp_name" ]; then
                printf 'Aborted.\n'
                unset _cp_name _cp_dir _cp_reply
                return 1
            fi
            # rm -rf removes symlinks themselves, never their targets, so the
            # shared ~/.claude config is not at risk here.
            rm -rf "$_cp_dir" && printf 'Deleted "%s".\n' "$_cp_name"
            printf 'Note: its keychain credential entry is left in place; remove it\n'
            printf 'manually from Keychain Access if you want it gone.\n'
            unset _cp_name _cp_dir _cp_reply
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
            if ! _claude_profile_exists "$_cp_name"; then
                printf 'claude-profile: no such profile: %s\n' "$_cp_name" >&2
                return 2
            fi
            _cp_dir="$CLAUDE_PROFILES_DIR/$_cp_name"
            [ "$1" = "--" ] && shift
            if [ $# -eq 0 ]; then
                set -- claude
            fi
            CLAUDE_CONFIG_DIR="$_cp_dir" CLAUDE_PROFILE="$_cp_name" command "$@"
            _cp_rc=$?
            unset _cp_name _cp_dir
            return $_cp_rc
            ;;

        audit)
            _cp_rc=0
            printf 'Auditing config shared across profiles.\n'
            printf 'Shared list: %s\n\n' "$CLAUDE_PROFILE_SHARED"

            _cp_found=$(_claude_profile_shared_items | while IFS= read -r _cp_item; do
                _claude_profile_scan_secrets "$HOME/.claude/$_cp_item"
            done)

            if [ -n "$_cp_found" ]; then
                printf 'FINDINGS — these are shared into every profile:\n'
                printf '%s\n' "$_cp_found" | sed 's/^/  /'
                printf '\nA shared file carrying credentials means one client session\n'
                printf 'runs with another client credentials loaded. Either remove the\n'
                printf 'secret, or drop that entry from CLAUDE_PROFILE_SHARED.\n'
                _cp_rc=1
            else
                printf 'No credential-shaped content in shared config.\n'
            fi

            # MCP servers are the classic inline-token offender. They live in
            # .claude.json inside each config dir, which is never shared — so
            # this is a check that the isolation still holds, not a scan of
            # the shared list.
            printf '\nMCP isolation:\n'
            for _cp_j in "$HOME/.claude.json" "$CLAUDE_PROFILES_DIR"/*/.claude.json; do
                [ -f "$_cp_j" ] || continue
                if [ -L "$_cp_j" ]; then
                    printf '  SHARED (!) %s -> %s\n' "$_cp_j" "$(readlink "$_cp_j")"
                    _cp_rc=1
                else
                    printf '  isolated   %s\n' "$_cp_j"
                fi
            done
            unset _cp_found _cp_j
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
            if [ -d "$CLAUDE_PROFILES_DIR" ]; then
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
            unset _cp_probe _cp_kind _cp_d _cp_n _cp_item
            return $_cp_rc
            ;;

        repair)
            _cp_target="${1:---all}"
            printf 'Repairing shared config.\n\n'

            # 1. The status line, in the shared settings file so one entry
            #    serves every profile.
            if [ ! -f "$HOME/.claude/settings.json" ]; then
                printf '{}\n' > "$HOME/.claude/settings.json"
            fi
            if grep -q '"statusLine"' "$HOME/.claude/settings.json" 2>/dev/null; then
                printf 'statusLine already present in ~/.claude/settings.json\n'
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
            for _cp_d in "$CLAUDE_PROFILES_DIR"/*; do
                [ -d "$_cp_d" ] || continue
                _cp_n=$(basename "$_cp_d")
                _claude_profile_exists "$_cp_n" || continue
                case "$_cp_target" in
                    --all | "$_cp_n") ;;
                    *) continue ;;
                esac
                printf '%s:\n' "$_cp_n"
                _cp_did=$(_claude_profile_shared_items | while IFS= read -r _cp_item; do
                    _claude_profile_link_item "$_cp_d" "$_cp_item"
                done)
                if [ -n "$_cp_did" ]; then
                    printf '%s\n' "$_cp_did" | sed 's/^/  /'
                else
                    printf '  already correct\n'
                fi
            done
            unset _cp_target _cp_d _cp_n _cp_did _cp_bak
            ;;

        path)
            _cp_dir=$(_claude_profile_dir "$1") || {
                printf 'claude-profile: invalid profile name\n' >&2
                return 1
            }
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

_claude_profiles_names() {
    [ -d "$CLAUDE_PROFILES_DIR" ] || return 0
    find "$CLAUDE_PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
        while IFS= read -r _cp_d; do
            _cp_b=$(basename "$_cp_d")
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
    # compdef only exists once compinit has run; ignore failure if it hasn't.
    if whence compdef >/dev/null 2>&1; then
        compdef _claude_profiles_complete claude 2>/dev/null
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
    complete -F _claude_profiles_complete_bash claude 2>/dev/null
fi
