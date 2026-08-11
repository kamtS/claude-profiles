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
CLAUDE_PROFILE_SHARED="settings.json skills agents commands plugins CLAUDE.md"

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

# --- the wrapper -------------------------------------------------------------

claude() {
    _cp_dir=""

    # Only claim a leading single-dash argument when it names a profile that
    # actually exists. Every real Claude Code flag (-c, -p, -d, -r, -v, ...)
    # therefore passes straight through untouched.
    case "$1" in
        --* | "") ;;
        -?*)
            _cp_name="${1#-}"
            if _claude_profile_valid_name "$_cp_name" &&
                [ -d "$CLAUDE_PROFILES_DIR/$_cp_name" ]; then
                _cp_dir="$CLAUDE_PROFILES_DIR/$_cp_name"
                shift
            fi
            unset _cp_name
            ;;
    esac

    if [ -n "$_cp_dir" ]; then
        CLAUDE_CONFIG_DIR="$_cp_dir" command claude "$@"
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

Once created, run Claude Code against a profile by prefixing its name:

  claude -<name> [args...]

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

            # Share non-account-specific config from the default profile.
            # Note: iterate via `tr` + `read`, NOT `for x in $CLAUDE_PROFILE_SHARED`.
            # zsh does not word-split unquoted scalars, so the plain `for` loop
            # silently linked nothing under zsh. This form behaves identically
            # in bash, zsh and dash, and accepts space- or newline-separated
            # values. The `ln` calls run in a subshell; their filesystem
            # effects persist, and the linked names come back on stdout.
            _cp_linked=$(printf '%s\n' "$CLAUDE_PROFILE_SHARED" | tr ' ' '\n' |
                while IFS= read -r _cp_item; do
                    [ -n "$_cp_item" ] || continue
                    if [ -e "$HOME/.claude/$_cp_item" ] && [ ! -e "$_cp_dir/$_cp_item" ]; then
                        ln -s "$HOME/.claude/$_cp_item" "$_cp_dir/$_cp_item" &&
                            printf '%s ' "$_cp_item"
                    fi
                done)

            printf 'Created profile "%s"\n' "$_cp_name"
            printf '  config dir: %s\n' "$_cp_dir"
            printf '  shared from ~/.claude: %s\n' "${_cp_linked:-nothing found to share}"
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
                    _claude_profile_valid_name "$_cp_n" || continue
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
        while IFS= read -r _cp_d; do basename "$_cp_d"; done
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
