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

Then wire up the status line, so every session says which profile it's billing:

```console
$ claude-profile repair
```

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

### Always know which profile you're in

If you bill clients per profile, the dangerous failure isn't an error — it's a session that quietly runs the *default* profile while you assume it's the client's. So the profile name is visible at all times rather than trusted to the launcher:

```console
$ claude-profile repair          # wires up the status line, once
```

Every session then carries its own identity, spend, and five-hour usage:

```
⬢ clientx · you@clientx.example · $2.14 · 34%/5h
```

A session with no profile renders `⬢ default` in a different colour, so an unlabelled session is itself the signal.

The renderer takes the name from the session's `transcript_path` — where Claude Code is *actually* writing — and cross-checks it against `CLAUDE_CONFIG_DIR`, which only records what the launcher *intended*. If those ever disagree, you get an alarm naming the account really being billed, instead of a confident wrong label:

```
⚠ PROFILE MISMATCH launcher=clientx billing=default
```

One `statusLine` entry in the shared `~/.claude/settings.json` covers every profile, because Claude Code runs the command per session with that session's own config dir.

### Scripts, cron and CI

`claude -work` is a **shell function**. Non-interactive shells never source your `~/.zshrc`, so in a script that prefix doesn't exist — and plain `claude` there silently uses the default profile, with no status line to give it away. Use `exec`:

```sh
claude-profile exec work -- claude -p "summarise this"
```

The same applies to IDE extensions and the desktop app: they launch the binary directly, never your shell function, so they always run the default profile. The status line will say `default` — believe it.

### Shared configuration

Logins should be separate. Your skills and settings usually shouldn't be.

When a profile is created, these are symlinked back to your default `~/.claude` so you maintain them in one place:

```
settings.json  skills  agents  commands  plugins  CLAUDE.md
```

**Nothing in that list may carry credentials.** A shared file is loaded into every client's session, so a secret inside one means you're running one client's work with another client's key in scope — the account isolation quietly leaking a level down. `claude-profile audit` checks for exactly that and exits non-zero if it finds anything:

```console
$ claude-profile audit
FINDINGS — these are shared into every profile:
  ~/.claude/settings.json: env var CLIENT_API_KEY injected into every profile
```

It reports key names and file paths, never values, so its output is safe to paste into a ticket.

MCP servers — the usual home of inline API keys and OAuth tokens — are **not** affected: Claude Code keeps them in `.claude.json` *inside* each config directory, which is never shared. `audit` verifies that isolation still holds rather than assuming it.

Anything absent is skipped. To change the list, set `CLAUDE_PROFILE_SHARED` before sourcing the script:

```sh
CLAUDE_PROFILE_SHARED="settings.json skills"   # share less
CLAUDE_PROFILE_SHARED=""                       # fully standalone profiles
```

Existing profiles aren't retroactively changed at `new` time — but `claude-profile repair` brings them up to date, and never destroys anything to do it (see below).

### When an update breaks something

Anything that depends on a wrapper or a config path can be undone by an update, and the failure is silent. `claude-profile doctor` checks the parts that can rot:

```console
$ claude-profile doctor
```

- `claude` still resolves, and our wrapper still wins — if something sourced *after* us redefines `claude`, it takes over and `claude -work` stops switching profiles without saying so.
- `CLAUDE_CONFIG_DIR` is still honoured, checked by running a real session against a throwaway directory and confirming config lands there. (Asking `claude --version` would prove nothing — it never touches the config dir.)
- The status line is wired up, so sessions still announce themselves.
- Every profile's shared links are intact — including a file that has stopped being a symlink.

That last one matters: if Claude Code ever writes `settings.json` by writing a temp file and renaming it over the top, the rename **replaces the symlink with a regular file** and the profile silently stops sharing. `doctor` reports it as `UNSHARED`, and `repair` relinks it — moving the diverged copy aside to `settings.json.unshared-<timestamp>` rather than deleting it, because that copy is the only record of whatever changed.

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

That's it. The wrapper claims a leading `-name` argument **only when `~/.claude-profiles/name` actually exists as a directory**, so every real Claude Code flag — `-c`, `-p`, `-d`, `-r`, `-v`, `-w` — passes straight through.

An unmatched `-foo` is a **hard error**, not a fallback:

```console
$ claude -clientx
claude-profile: no profile "clientx" in ~/.claude-profiles
Refusing to fall back to the default profile.
```

Falling through to the default was the old behaviour, and it's the exact shape of the expensive mistake: rename a profile, move `CLAUDE_PROFILES_DIR`, restore a machine, or just mistype, and you'd bill your personal account without a word. Erroring is cheap; the alternative isn't.

To avoid that check breaking a future Claude Code flag we've never heard of, an unmatched argument is looked up in `claude --help` before being rejected — so a genuine flag still passes through, and only a real typo errors. That lookup happens only on the failure path, so the normal case costs nothing.

Profile names must start with a letter or digit and may contain only letters, digits, dot, underscore and hyphen. Single-character names are rejected because they would shadow short flags.

## Security notes

Worth knowing before you trust it with more than one account:

- **Credential storage is Claude Code's, not ours.** This tool never reads, writes or moves credentials. It only sets an environment variable telling Claude Code which directory to use. On macOS, credentials go to the login keychain under `Claude Code-credentials-<hash>`, where the hash derives from the config directory — that's what keeps profiles from overwriting each other. On Linux they land in a file inside the profile directory; profile directories are created `700`.
- **`ls` reads one field.** `claude-profile ls` reads `oauthAccount.emailAddress` from each profile's `.claude.json` purely to label rows. Nothing is sent anywhere.
- **Deleting a profile deletes a directory of symlinks.** `rm -rf` removes symlinks themselves, never their targets, so your shared `~/.claude` config is not at risk. The path is validated to be a direct child of the profiles directory, and symlinked profile directories are refused outright.
- **Keychain entries outlive `rm`.** Deleting a profile leaves its keychain credential entry behind. Remove it from Keychain Access if you want it gone. Erasing keychain items on your behalf felt like the wrong default for a tool this small.
- **Shared symlinks mean shared trust.** A skill or plugin shared into every profile runs in every workspace. Worse, a shared file that *carries a secret* puts one client's credentials in every other client's session — account isolation leaking one level down. Run `claude-profile audit` before trusting the shared list, and again whenever you add to it. If you need a client profile that genuinely shares nothing, create it with `CLAUDE_PROFILE_SHARED=""`.
- **The wrapper only exists in interactive shells.** Scripts, cron, CI, IDE extensions and the desktop app all bypass it and use the default profile. Use `claude-profile exec <name> -- ...` for the first three; for the last two, watch the status line.
- **This is not a security boundary.** It separates *accounts*, not *privileges*. Anything running as your user can read every profile. Use separate OS user accounts if you need a real boundary.

Profile names are validated against a strict allowlist and every path is quoted, so names containing shell metacharacters, `..`, or absolute paths are rejected rather than interpolated. The test suite (`test/redteam.sh`) covers path traversal, command injection, canary files that must survive deletion, hostile JSON, flag pass-through, the refusal to fall back to the default profile, status line identity and mismatch detection, credential auditing, and `repair` preserving a diverged file — in both bash and zsh.

## Unofficial

Not affiliated with, endorsed by, or supported by Anthropic. It relies on `CLAUDE_CONFIG_DIR`, which is a documented Claude Code environment variable, but the rest is a shell convenience layer. If Claude Code ever ships native profile support, use that instead.

## Licence

MIT — see [LICENSE](LICENSE).

Built by [Dan Johnson](https://danjohnson.au). More small tools at [danjohnson.au/tools](https://danjohnson.au/tools/).
