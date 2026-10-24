# Operations

How to run, connect to, check and recover a HerdQuay container. The local Compose harness
(`compose.yaml`) is the reference; a deployment must provide the same interface
([deployment.md](deployment.md)).

## Interface

| Item | Value |
| --- | --- |
| User | `herdquay`, UID:GID 568:568 (build args `HERDQUAY_UID`, `HERDQUAY_GID`); no root at run time, no sudo |
| SSH | port 2222, keys only, user `herdquay` |
| PID 1 | `tini`, then `herdquay-entrypoint`, which supervises `sshd` and `herdr server` |
| Healthcheck | sshd listening on 2222 and the Herdr server answering (`herdquay-healthcheck`) |
| Logs | stdout/stderr: the entrypoint, sshd (`-e`) and the Herdr server's start line; Herdr's own log is `~/.config/herdr/herdr-server.log` |

### Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `HERDQUAY_AUTHORIZED_KEYS_FILE` | `/run/secrets/authorized_keys` | public keys allowed to SSH in; required, rebuilt into `~/.ssh/authorized_keys` on every start |
| `HERDQUAY_GITHUB_TOKEN_FILE` | `/run/secrets/github_token` | fine-grained GitHub token for `gh` and Git over HTTPS; optional |
| `HERDQUAY_GIT_NAME`, `HERDQUAY_GIT_EMAIL` | unset | Git identity, written to `~/.gitconfig` only when it has none |
| `HERDQUAY_GIT_SIGNING_KEY_FILE` | `/run/secrets/git_signing_key` | armored GPG secret key without a passphrase; with `HERDQUAY_GIT_NAME` and `HERDQUAY_GIT_EMAIL`, commits and tags are signed ([Commit signing](#commit-signing)); optional |
| `HERDQUAY_STOP_TIMEOUT` | `15` | seconds a child gets after SIGTERM before SIGKILL; keep it below the orchestrator's stop grace period (30 s in the harness) |
| `HERDQUAY_AGENT_RESTORE` | `0` | `1` makes `herdquay-agents` resume the Claude agents itself (turn Herdr's native restore off with it) |
| `HERDQUAY_CLAUDE_INSTALL` | `1` | `0` skips installing Claude Code at start (the tests use it on throwaway volumes) |
| `HERDQUAY_CLAUDE_INSTALL_TIMEOUT` | `300` | seconds each Claude Code download may take |
| `HERDQUAY_AGENT_VERIFY_DELAY` | `120` | seconds after start before `herdquay-agents verify` checks the resumed sessions |

The SSH key for GitHub is always read from `/run/secrets/github_ssh_key`
(`/etc/ssh/ssh_config.d/herdquay.conf`).

### Claude Code at first start

The image does not contain Claude Code: its license grants no right to redistribute it. Before
sshd and Herdr start, `herdquay-claude-install` downloads the release the image pins (about
290 MB), checks that its manifest is signed by Anthropic's release key and that the binary
matches the manifest's checksum, and installs it as Anthropic's installer would:
`~/.local/share/claude/versions/<version>`, linked from `~/.local/bin/claude`. The next starts
only re-link it. A new image with another pin installs that one and removes the rest, and so
does a restart after a manual `claude update`: the pin wins.

If the download or a check fails, the container still starts, without Claude Code:
`herdquay doctor` fails on it, and the next start tries again. The first start of a new pin needs
outbound HTTPS to `downloads.claude.ai`; the healthcheck's start period (6 minutes) covers the
download.

### Commit signing

GitHub shows a commit as Verified only when its signing key is registered on the account the
commit's email belongs to. So signing applies to the identity set with `HERDQUAY_GIT_NAME` and
`HERDQUAY_GIT_EMAIL`; the GitHub App's bot cannot register a key, its commits stay unsigned, and a
key mounted with the bot identity is ignored (logged at start, reported by `herdquay doctor`).
Signing is off without a key.

Create a dedicated signing-only key with an expiry and no passphrase (nothing could unlock one
unattended), on the desktop, register its public half, and provision the secret half:

```bash
gpg --quick-gen-key "Roberto Leinardi <leinardi@gmail.com>" ed25519 sign 1y   # empty passphrase
gpg --armor --export <fingerprint> >herdquay-signing.pub.asc
gh gpg-key add herdquay-signing.pub.asc
gpg --armor --export-secret-keys <fingerprint> >herdquay-signing.asc
scripts/local-secrets.sh --git-signing-key herdquay-signing.asc   # local harness
rm herdquay-signing.asc
```

At start the entrypoint adds `gpg.program`, `user.signingkey`, `commit.gpgsign` and `tag.gpgsign`
to `~/.config/herdquay/identity.gitconfig`; a value in `~/.gitconfig` still overrides them.
`herdquay-gpg` imports the key into `/tmp/herdquay-gnupg`, never `~/.gnupg`, and imports it again
whenever the secret's content changes, so a renewal (`gpg --quick-set-expire`, then the secret
updated) needs no restart. `herdquay doctor` shows whether signing is on, the key's fingerprint and
expiry, warns when no UID of the key matches the commit email (GitHub would show Unverified) or
when the key is ignored for the bot, and makes a test signature. To revoke the key:
`gh gpg-key delete <id>`, then remove the secret; commits already pushed may keep their Verified
status, so review what the key signed. In the local harness, the signing key is mounted by
`compose.github.yaml`, so only together with the App key.

## Local harness

```bash
make local-secrets      # local/secrets/authorized_keys from ~/.ssh/id_ed25519.pub (or ecdsa, rsa)
make compose-up         # builds the image and starts it
make compose-logs
make compose-down       # stops it; the home and workspace volumes stay
```

With GitHub credentials, provision them too; `make compose-up` then adds `compose.github.yaml`:

```bash
scripts/local-secrets.sh --authorized-keys ~/.ssh/id_ed25519.pub \
  --github-ssh-key ~/.ssh/herdquay_github --github-token-file /path/to/token-file
```

The files stay yours, mode 0600, and a POSIX ACL lets UID 568 read them, nobody else (the script
explains why and checks it).

## First connection from the desktop

1. The first start logs the host key fingerprint:
   `herdquay: SSH host key: 256 SHA256:… herdquay-host (ED25519)`. Compare it on the first
   `ssh` and accept it.
2. Add an SSH alias (the harness listens on loopback):

   ```text
   Host herdquay-local
     HostName 127.0.0.1
     Port 2222
     User herdquay
   ```

3. `herdr machine add herdquay-local --label HerdQuay`, then open the machine in Herdr. Herdr
   uses the `herdr` binary on the container's PATH and never installs one there.
4. In a pane, work inside `~/workspace/<project>`, run `claude`, then `/login` once with the
   claude.ai account (Remote Control does not work with an API key). Accept the workspace trust
   prompt: Remote Control needs a trusted workspace, and the home directory is never saved as
   trusted.

Every interactive Claude session starts with Remote Control on (`remoteControlAtStartup: true`,
seeded into `~/.claude/settings.json`), so the conversation shows up in the Claude app.

opencode is there too: run `opencode` in a pane and `opencode auth login` once per provider.
The entrypoint installs Herdr's opencode integration, so Herdr shows its state like Claude's.
Remote Control is Claude's alone, so opencode is desktop only, and `herdquay-agents` checks and
resumes only Claude conversations.

## Disconnects and restarts

| Event | What happens |
| --- | --- |
| Desktop client detaches or loses the network | nothing stops: panes, Claude and Remote Control keep running; reattach any time |
| Container restart or recreation | every process ends. Herdr restores the layout and resumes each Claude conversation (`claude --resume <id>`) with no client attached, and Remote Control comes back with it |
| A conversation that never got a message | has no transcript, so it cannot be resumed; its pane comes back as a shell |
| sshd or the Herdr server dies | the container exits non-zero and the orchestrator restarts it |

About two minutes after a start, `herdquay-agents verify` logs whether every recorded
conversation came back, and writes `~/.local/state/herdquay/agents-status.json`. A conversation
it reports can be resumed by hand with `claude --resume <id>` in its directory.

Running commands, dev servers and shells do not survive a restart: only the layout and the Claude
conversations do.

## Checking the environment

```bash
herdquay doctor            # identity, services, secrets, tools: ok / warn / FAIL
herdquay doctor --network  # also authenticates to GitHub over SSH and with the token
```

## Recovery

| Problem | Fix |
| --- | --- |
| The host key changed unexpectedly | stop: a new key means the home volume was replaced. If intended, remove the old `known_hosts` entry and compare the new fingerprint from the logs |
| Locked out (lost the authorized key) | update the authorized keys secret and restart; the file is rebuilt on every start |
| Claude asks to log in again | `/login` in a pane; the credentials live in `~/.claude/.credentials.json` on the home volume |
| Claude Code is missing or not the pinned version | the start log says why; restart, or run `herdquay-claude-install` in a shell |
| A conversation did not come back | `herdquay doctor` names it; `claude --resume <id>` in its directory |
| Herdr's native restore stops working after an upgrade | set `resume_agents_on_restore = false` in `~/.config/herdr/config.toml` and `HERDQUAY_AGENT_RESTORE=1` |
| Start from scratch | remove the home volume: a new host key, a new Claude login and an empty Herdr layout |
