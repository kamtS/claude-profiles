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

cat <<EOF

Installed to $TARGET

Next steps:
  exec \$SHELL                 reload your shell
  claude-profile new work     create a profile and log into it
  claude -work                run Claude Code as that profile
  claude-profile ls           see every profile and its account
EOF
