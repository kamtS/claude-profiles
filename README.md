# claude-profiles

Run [Claude Code](https://claude.com/claude-code) against multiple workspace logins from one terminal, by prefixing a profile name:

```console
$ claude -work        # your employer's workspace
$ claude -clientx     # a client's workspace
$ claude              # your personal account, unchanged
```

No re-login, no logging out and back in, no second machine.

## Why

Claude Code stores one active login at a time. If you have a personal subscription and a work workspace — or you consult across several client organisations — switching means logging out and back in, which also throws away that workspace's MCP server auth and session history.

Claude Code does respect a `CLAUDE_CONFIG_DIR` environment variable that relocates its entire config directory. `claude-profiles` is a small shell wrapper around that: each profile is its own config directory, so each keeps its own credentials, MCP servers, project state and history. On macOS the system keychain namespaces Claude Code's credentials per config directory, so the logins never collide.

It's a couple of hundred lines of shell. No daemon, no dependencies, nothing to trust beyond a file you can read in one sitting.

## Install

```console
$ git clone https://github.com/kamtS/claude-profiles.git
$ cd claude-profiles
$ ./install.sh
$ exec $SHELL
```

The installer copies the script to `~/.claude-profiles/claude-profiles.sh` and adds one `source` line to your `~/.zshrc` or `~/.bashrc`, wrapped in markers so `./install.sh --uninstall` can remove it cleanly.

Prefer to do it by hand? Copy `claude-profiles.sh` anywhere and source it from your shell rc. That's the whole install.

**Requires** Claude Code on your `PATH`, and bash or zsh. Tested on macOS; the config-directory mechanism works on Linux too, but credentials there live in a file rather than a keychain (see [Security notes](#security-notes)).

## Use

```console
$ claude-profile new work
```

Creates the profile and drops you into Claude Code so you can log in as that workspace. Then:

```console
$ claude -work                       # interactive session
$ claude -work -p "summarise this"   # flags pass through untouched
$ claude -work --model sonnet
```

List what you have:

```console
$ claude-profile ls
PROFILE          ACCOUNT
(default)        you@personal.example
-work            you@employer.example
-clientx         you@clientx.example
```

Remove one:

```console
$ claude-profile rm clientx
```

You'll be asked to type the profile name to confirm. Tab completion for `claude -<TAB>` is set up automatically in both shells.

### Shared configuration

Logins should be separate. Your skills and settings usually shouldn't be.

When a profile is created, these are symlinked back to your default `~/.claude` so you maintain them in one place:

```
settings.json  skills  agents  commands  plugins  CLAUDE.md
```

Anything absent is skipped. To change the list, set `CLAUDE_PROFILE_SHARED` before sourcing the script:

```sh
CLAUDE_PROFILE_SHARED="settings.json skills"   # share less
CLAUDE_PROFILE_SHARED=""                       # fully standalone profiles
```

Existing profiles aren't retroactively changed — the links are created once, at `new` time. Add or remove them yourself afterwards; they're just symlinks.

### What is *not* shared

Deliberately, so workspaces stay properly separate:

- **Credentials.** The whole point.
- **MCP server auth.** A new profile starts with its MCP servers unauthenticated, so you re-auth them there. This is a feature — you rarely want a client workspace holding your personal Linear token.
- **Session history and project state.** `claude -c` and `claude -r` only see that profile's sessions.

## How it works

```sh
claude -work chat
  → CLAUDE_CONFIG_DIR=~/.claude-profiles/work command claude chat
```

That's it. The wrapper claims a leading `-name` argument **only when `~/.claude-profiles/name` actually exists as a directory**, so every real Claude Code flag — `-c`, `-p`, `-d`, `-r`, `-v`, `-w` — passes straight through. An unrecognised `-foo` reaches the real CLI and produces the real CLI's error, not ours.

Profile names must start with a letter or digit and may contain only letters, digits, dot, underscore and hyphen. Single-character names are rejected because they would shadow short flags.

## Security notes

Worth knowing before you trust it with more than one account:

- **Credential storage is Claude Code's, not ours.** This tool never reads, writes or moves credentials. It only sets an environment variable telling Claude Code which directory to use. On macOS, credentials go to the login keychain under `Claude Code-credentials-<hash>`, where the hash derives from the config directory — that's what keeps profiles from overwriting each other. On Linux they land in a file inside the profile directory; profile directories are created `700`.
- **`ls` reads one field.** `claude-profile ls` reads `oauthAccount.emailAddress` from each profile's `.claude.json` purely to label rows. Nothing is sent anywhere.
- **Deleting a profile deletes a directory of symlinks.** `rm -rf` removes symlinks themselves, never their targets, so your shared `~/.claude` config is not at risk. The path is validated to be a direct child of the profiles directory, and symlinked profile directories are refused outright.
- **Keychain entries outlive `rm`.** Deleting a profile leaves its keychain credential entry behind. Remove it from Keychain Access if you want it gone. Erasing keychain items on your behalf felt like the wrong default for a tool this small.
- **Shared symlinks mean shared trust.** A skill or plugin shared into every profile runs in every workspace. If you need a client profile that genuinely shares nothing, create it with `CLAUDE_PROFILE_SHARED=""`.
- **This is not a security boundary.** It separates *accounts*, not *privileges*. Anything running as your user can read every profile. Use separate OS user accounts if you need a real boundary.

Profile names are validated against a strict allowlist and every path is quoted, so names containing shell metacharacters, `..`, or absolute paths are rejected rather than interpolated. The test suite (`test/redteam.sh`) covers path traversal, command injection, canary files that must survive deletion, hostile JSON, and flag pass-through, in both bash and zsh.

## Unofficial

Not affiliated with, endorsed by, or supported by Anthropic. It relies on `CLAUDE_CONFIG_DIR`, which is a documented Claude Code environment variable, but the rest is a shell convenience layer. If Claude Code ever ships native profile support, use that instead.

## Licence

MIT — see [LICENSE](LICENSE).

Built by [Dan Johnson](https://danjohnson.au). More small tools at [danjohnson.au/tools](https://danjohnson.au/tools/).
