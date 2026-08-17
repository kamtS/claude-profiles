#!/usr/bin/env bash
# claude-profiles installer
# https://github.com/kamtS/claude-profiles
#
#   ./install.sh              install for the current shell
#   ./install.sh --uninstall  remove the source line (profiles are kept)
#
# Idempotent: running it twice will not duplicate anything.

set -euo pipefail

INSTALL_DIR="${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"
TARGET="$INSTALL_DIR/claude-profiles.sh"
MARKER="# >>> claude-profiles >>>"
MARKER_END="# <<< claude-profiles <<<"

detect_rc() {
    if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
        printf '%s\n' "$HOME/.zshrc"
    else
        # Prefer an existing bash rc rather than creating a new one.
        for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
            [ -f "$f" ] && { printf '%s\n' "$f"; return; }
        done
        printf '%s\n' "$HOME/.bashrc"
    fi
}

RC="${CLAUDE_PROFILES_RC:-$(detect_rc)}"

if [ "${1:-}" = "--uninstall" ]; then
    if [ -f "$RC" ] && grep -qF "$MARKER" "$RC"; then
        # Rewriting someone's shell rc is the most destructive thing this
        # script does, so: back it up, write to a temp file, and refuse to
        # install the result unless awk succeeded AND the output still has
        # content. Better to leave a stale block than to truncate a dotfile.
        backup="$RC.claude-profiles-backup.$(date +%Y%m%d%H%M%S)"
        cp "$RC" "$backup"

        tmp=$(mktemp)
        if ! awk -v s="$MARKER" -v e="$MARKER_END" '
            $0 == s { skip = 1 } !skip { print } $0 == e { skip = 0 }
        ' "$RC" > "$tmp"; then
            rm -f "$tmp"
            echo "install.sh: failed to rewrite $RC; left it unchanged." >&2
            echo "A backup is at $backup" >&2
            exit 1
        fi

        # The block is 3 lines; anything shorter than that difference means
        # something went wrong.
        orig_lines=$(wc -l < "$RC")
        new_lines=$(wc -l < "$tmp")
        if [ "$new_lines" -lt $((orig_lines - 5)) ]; then
            rm -f "$tmp"
            echo "install.sh: refusing to rewrite $RC (would remove too much)." >&2
            echo "Remove the block between the claude-profiles markers by hand." >&2
            echo "A backup is at $backup" >&2
            exit 1
        fi

        cat "$tmp" > "$RC"
        rm -f "$tmp"
        echo "Removed the claude-profiles block from $RC"
        echo "Backup saved to $backup"
    else
        echo "No claude-profiles block found in $RC"
    fi
    echo "Your profiles in $INSTALL_DIR were left untouched."
    echo "Delete them yourself if you want them gone."
    exit 0
fi

src_dir=$(cd "$(dirname "$0")" && pwd)
if [ ! -f "$src_dir/claude-profiles.sh" ]; then
    echo "install.sh: claude-profiles.sh not found next to this script" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR" 2>/dev/null || true

# Don't copy a file onto itself if someone runs the installer from the
# install directory.
if [ "$src_dir/claude-profiles.sh" != "$TARGET" ]; then
    cp "$src_dir/claude-profiles.sh" "$TARGET"
fi

# The status line renderer. This is what makes a wrong profile visible rather
# than silent, so treat a failure to install it as fatal.
if [ -f "$src_dir/bin/profile-status.sh" ]; then
    mkdir -p "$INSTALL_DIR/bin"
    if [ "$src_dir/bin/profile-status.sh" != "$INSTALL_DIR/bin/profile-status.sh" ]; then
        cp "$src_dir/bin/profile-status.sh" "$INSTALL_DIR/bin/profile-status.sh"
    fi
    chmod +x "$INSTALL_DIR/bin/profile-status.sh"
else
    echo "install.sh: bin/profile-status.sh not found next to this script" >&2
    exit 1
fi

if [ -f "$RC" ] && grep -qF "$MARKER" "$RC"; then
    echo "Already installed in $RC (script refreshed)."
else
    # zsh-syntax-highlighting and similar plugins insist on being sourced
    # last, so append rather than prepend and tell the user if we spot one.
    {
        printf '\n%s\n' "$MARKER"
        printf '[ -f "%s" ] && . "%s"\n' "$TARGET" "$TARGET"
        printf '%s\n' "$MARKER_END"
    } >> "$RC"
    echo "Added the claude-profiles block to $RC"

    if grep -q "zsh-syntax-highlighting" "$RC" 2>/dev/null; then
        echo
        echo "Note: $RC sources zsh-syntax-highlighting, which must stay last."
        echo "Move the claude-profiles block above that line."
    fi
fi

# Our wrapper is a shell function, so whoever defines `claude` LAST wins. A
# Claude Code update that appends its own alias or function to the rc is the
# most likely way this silently stops working — and the symptom is not an
# error, it is every session quietly running the default profile.
if [ -f "$RC" ] && grep -qF "$MARKER_END" "$RC"; then
    if awk -v e="$MARKER_END" '
        $0 == e { after = 1; next }
        after && /(alias|function)[[:space:]]+claude([[:space:]]|=|\()/ { found = 1 }
        after && /^[[:space:]]*claude[[:space:]]*\(\)/ { found = 1 }
        END { exit !found }
    ' "$RC"; then
        echo
        echo "WARNING: something after the claude-profiles block in $RC also"
        echo "defines 'claude'. It will win, and 'claude -<name>' will silently"
        echo "run the default profile. Move the claude-profiles block below it,"
        echo "then confirm with: claude-profile doctor"
    fi
fi

# A SECOND copy of claude-profiles sourced from somewhere else in the same rc.
# The check above deliberately only looks after our block, because only a later
# definition can win — but a second copy sourced EARLIER is its own trap. It
# will not misroute a profile: ours is appended last, so ours wins. The other
# file just quietly becomes a decoy, still sourced, always overridden, never
# erroring. Edit it expecting a deploy and nothing at all happens.
if [ -f "$RC" ]; then
    # Every distinct token containing a slash on a `source`/`.` line. sort -u
    # because a guarded source names the same path twice on one line:
    #   [ -f "$HOME/x.zsh" ] && source "$HOME/x.zsh"
    grep -E '^[^#]*([[:space:];&]|^)(\.|source)[[:space:]]' "$RC" 2>/dev/null |
        tr '[:blank:]' '\n' | tr -d "\"'" | sort -u |
        while IFS= read -r candidate; do
            case "$candidate" in
                */*) ;;
                *) continue ;;
            esac
            # Expand the forms an rc realistically uses. The single quotes are
            # deliberate: these are literal patterns to match, not expansions.
            # shellcheck disable=SC2016
            case "$candidate" in
                '$HOME'/*) candidate="$HOME/${candidate#\$HOME/}" ;;
                '${HOME}'/*) candidate="$HOME/${candidate#\$\{HOME\}/}" ;;
                '~'/*) candidate="$HOME/${candidate#\~/}" ;;
            esac
            [ -f "$candidate" ] || continue
            [ "$candidate" = "$TARGET" ] && continue
            # Our signature: an internal only this project defines.
            grep -q '_claude_profile_valid_name' "$candidate" 2>/dev/null || continue
            echo
            echo "WARNING: $RC also sources another copy of claude-profiles:"
            echo "  $candidate"
            echo "Ours is sourced last so it wins, but that file is now a decoy:"
            echo "still loaded, always overridden, and silent about it. Editing it"
            echo "will look like a deploy and change nothing."
            echo "Fix: delete it and remove its source line, or point that line at"
            echo "  $TARGET"
            echo "Then confirm with: claude-profile doctor"
        done
fi

cat <<EOF

Installed to $TARGET
Status line renderer: $INSTALL_DIR/bin/profile-status.sh

Next steps:
  exec \$SHELL                 reload your shell
  claude-profile repair       wire up the status line, so every session
                              shows which profile it is billing
  claude-profile new work     create a profile and log into it
  claude -work                run Claude Code as that profile
  claude-profile ls           see every profile and its account
  claude-profile doctor       check it all still works after an update
  claude-profile audit        check shared config carries no credentials

In scripts and cron, where your shell rc is never sourced, the 'claude -work'
prefix does not exist. Use this instead, or you will bill the default profile:
  claude-profile exec work -- claude -p '...'
EOF
