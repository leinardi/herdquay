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
| `HERDQUAY_GITHUB_APP_ID` | unset | the GitHub App's ID (or client ID); with the App key, Git and `gh` authenticate as the App ([GitHub App](#github-app)) |
| `HERDQUAY_GITHUB_APP_KEY_FILE` | `/run/secrets/github_app_key` | the GitHub App's private key; optional |
| `HERDQUAY_GITHUB_API_URL` | `https://api.github.com` | the REST API the tokens are minted from (the tests point it at a stub) |
| `HERDQUAY_GIT_NAME`, `HERDQUAY_GIT_EMAIL` | unset | the commit identity, both or neither; unset, the App's bot (`<slug>[bot]`). Written to `~/.config/herdquay/identity.gitconfig` at every start; a `user.name` or `user.email` in `~/.gitconfig` overrides it |
| `HERDQUAY_GIT_SIGNING_KEY_FILE` | `/run/secrets/git_signing_key` | armored GPG secret key without a passphrase; with `HERDQUAY_GIT_NAME` and `HERDQUAY_GIT_EMAIL`, commits and tags are signed ([Commit signing](#commit-signing)); optional |
| `HERDQUAY_STOP_TIMEOUT` | `15` | seconds a child gets after SIGTERM before SIGKILL; keep it below the orchestrator's stop grace period (30 s in the harness) |
| `HERDQUAY_AGENT_RESTORE` | `0` | `1` makes `herdquay-agents` resume the Claude agents itself (turn Herdr's native restore off with it) |
| `HERDQUAY_CLAUDE_INSTALL` | `1` | `0` skips installing Claude Code at start (the tests use it on throwaway volumes) |
| `HERDQUAY_CLAUDE_INSTALL_TIMEOUT` | `300` | seconds each Claude Code download may take |
| `HERDQUAY_RUST_INSTALL` | `1` | `0` skips installing rustup and the stable Rust toolchain at start ([Rust](#rust)) |
| `HERDQUAY_RUST_INSTALL_TIMEOUT` | `600` | seconds each rustup run at start may take |
| `HERDQUAY_AGENT_VERIFY_DELAY` | `120` | seconds after start before `herdquay-agents verify` checks the resumed sessions |

The entrypoint writes the GitHub variables that are set (never a key) to
`~/.config/herdquay/github.env` at every start, because SSH sessions do not inherit the
container's environment.

### GitHub App

HerdQuay reaches GitHub over HTTPS only, as a GitHub App. The only long-lived secret is the App's
private key; `herdquay-github` mints installation tokens from it, valid for one hour:

- **Git**: the credential helper (`/etc/gitconfig`, `credential.useHttpPath`) asks for a token
  restricted to the one repository being pushed or fetched. SSH remotes and clone URLs
  (`git@github.com:…`, `ssh://git@github.com/…`) are rewritten to HTTPS, so existing clones keep
  working.
- **`gh`**: the wrapper puts an installation-wide token in `GH_TOKEN` for its own process; an
  explicit `GH_TOKEN` or `GITHUB_TOKEN` wins. Pull requests and issues it creates show the App's
  bot as their author.
- Tokens are cached in `/dev/shm/herdquay-github` (the container's RAM tmpfs) and minted again
  five minutes before they expire; nothing is stored on disk or in `~/.config/gh/hosts.yml`.

Not supported with an App token: anything that acts as a user, such as `gh api user`, and
authenticated Gist operations (Gists belong to a user, so there is no credential helper for
`gist.github.com`).

Set up the App once, on the GitHub account that owns the repositories:

1. Settings → Developer settings → GitHub Apps → New GitHub App. Its name gives the slug, and the
   bot's name `<slug>[bot]`. Turn the webhook off. Install it only on this account.
2. Repository permissions: Contents read and write, Pull requests read and write, Issues read and
   write, Workflows read and write, Actions read-only, Metadata read-only. Nothing else.
3. Note the App ID on the App's page, and generate a private key (a `.pem` download).
4. Install the App on the account: "All repositories" includes every current and future
   repository; "Only select repositories" narrows what the key can reach
   ([security.md](security.md)), and a repository outside the selection fails with "the GitHub
   App is not installed on `<owner>/<repo>`".
5. Provide the key as the `github_app_key` secret and the ID as `HERDQUAY_GITHUB_APP_ID`
   ([Local harness](#local-harness), [deployment.md](deployment.md)), then delete the download.

The commit identity is the App's bot (`<id>+<slug>[bot]@users.noreply.github.com`) unless
`HERDQUAY_GIT_NAME` and `HERDQUAY_GIT_EMAIL` set another one, for example the owner's own name and
email. `herdquay doctor` shows the identity and where it comes from.

### Claude Code at first start

The image does not contain Claude Code: its license grants no right to redistribute it. Before
sshd and Herdr start, `herdquay-claude-install` downloads the release the image pins (about
290 MB), checks that its manifest is signed by Anthropic's release key and that the binary
matches the manifest's checksum, and installs it as Anthropic's installer would:
`~/.local/share/claude/versions/<version>`, linked from `~/.local/bin/claude`.

From then on Claude Code updates itself: its auto-update downloads new releases in the background,
and each session runs the new version from its next start. `claude update` does the same at once.
The pin is a minimum: a start keeps whatever version is linked, as long as it is at or above the
pin, and only installs the pin over a missing, broken or older one (removing the versions below
it).

opencode works the same way. The image carries a verified copy outside the `PATH`, and each start
copies it to `~/.opencode/bin/opencode`, where opencode's own installer puts it, unless a version
at or above it is already there. Its auto-update and `opencode upgrade` then replace it in place.

If the download or a check fails, the container still starts, without Claude Code:
`herdquay doctor` fails on it, and the next start tries again. The first start of a new pin needs
outbound HTTPS to `downloads.claude.ai`; the healthcheck's start period (6 minutes) covers the
download.

### Rust

Rust is not in the image either, only rustup's installer, verified at build. At start,
`herdquay-rust-install` installs rustup and the stable toolchain (minimal profile, with `rustfmt`
and `clippy`) into `~/.rustup` and `~/.cargo`, on the home volume. The image's Rust version is a
minimum, not a pin: `rustup update` upgrades rustup and the toolchains whenever needed, without a
new image, and a project's `rust-toolchain.toml` installs its own channel on first use. A start
leaves a default toolchain at or above the minimum alone, with no network access; only a missing
rustup or an older default toolchain makes it install the current stable (and make it the default).

If rustup cannot be installed, the container still starts without Rust: `herdquay doctor` fails
on it, and the next start tries again. The first start needs outbound HTTPS to
`static.rust-lang.org`.

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

At start the entrypoint adds `gpg.program`, `user.signingkey`, `commit.gpgsign` and `tag.gpgsign` to
`~/.config/herdquay/identity.gitconfig`; a value in `~/.gitconfig` still overrides them.
`herdquay-gpg` imports the key into `/dev/shm/herdquay-gnupg` (RAM), never `~/.gnupg`, and imports
it again whenever the secret's content changes, so a renewal (`gpg --quick-set-expire`, then the
secret updated) needs no restart. `herdquay doctor` shows whether signing is on, the key's
fingerprint and expiry, warns when no UID of the key matches the commit email (GitHub would show
Unverified) or when the key is ignored for the bot, and makes a test signature. To revoke the key:
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

With the GitHub App, provision its key too; `make compose-up` then adds `compose.github.yaml`,
which needs `HERDQUAY_GITHUB_APP_ID` in the shell or in `.env` (and takes `HERDQUAY_GIT_NAME` and
`HERDQUAY_GIT_EMAIL` from there too):

```bash
scripts/local-secrets.sh --authorized-keys ~/.ssh/id_ed25519.pub \
  --github-app-key ~/Downloads/herdquay.2026-10-24.private-key.pem
HERDQUAY_GITHUB_APP_ID=123456 make compose-up
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

## Dotfiles with chezmoi

`chezmoi` is in the image, so personal dotfiles (shell, editor, Claude Code and opencode settings)
can be applied to the home volume, where they persist like the rest of it:

```bash
chezmoi init --apply https://github.com/<owner>/<dotfiles>.git
```

The clone goes through the GitHub App, so a private dotfiles repository works if the App is
installed on it. `chezmoi update` pulls and applies later changes. A template or
`.chezmoiignore` can branch on the hostname (`herdquay` in the local harness; the deployment sets
its own) to keep desktop-only files out.

Some files in the home volume belong to HerdQuay, and must not be managed whole:

| Path | Why |
| --- | --- |
| `~/.ssh/authorized_keys`, `~/.ssh/host/` | rebuilt from the secret at every start; the SSH host key |
| `~/.ssh/config` | GitHub is reached over HTTPS with App tokens; a desktop config's keys and hosts do not apply |
| `~/.gitconfig` | the identity, credential helper and HTTPS rewrites come from the image (`/etc/gitconfig`, `~/.config/herdquay/identity.gitconfig`): a `user.*`, `credential.*`, `url.*.insteadOf` or signing setting there overrides them |
| `~/.claude/settings.json` | HerdQuay adds `remoteControlAtStartup`, and Herdr its `SessionStart` hook, at every start: merge with a `modify_` script instead of replacing the file |
| `~/.config/opencode/` | Herdr's opencode plugin is installed there at every start |
| `~/.config/herdr/config.toml` | `resume_agents_on_restore` drives the session restore |
| `~/.config/herdquay/` | rewritten at every start |

Keep secrets and password-manager templates out of the HerdQuay profile, and any setting that
turns off Claude Code's or opencode's updates (`DISABLE_AUTOUPDATER`, `autoupdate`).

## Checking the environment

```bash
herdquay doctor            # identity, services, secrets, tools: ok / warn / FAIL
herdquay doctor --network  # also mints an App token, lists a repository, git ls-remote over HTTPS
```

## Upgrades

### Identity seeded by an older image

Images before the GitHub App wrote `HERDQUAY_GIT_NAME` and `HERDQUAY_GIT_EMAIL` once into the
persistent `~/.gitconfig`. Those entries still override the identity the entrypoint now writes,
and nothing removes them: a seeded value cannot be told apart from one set by hand.
`herdquay doctor` warns when `~/.gitconfig` sets a `user.name` or `user.email` that differs from
the configured identity. If they were seeded, remove them:

```bash
git config --global --unset user.name
git config --global --unset user.email
```

### Upgrading from the SSH key

Removing the old mounts and configuration revokes nothing: the SSH key and the fine-grained token
keep working on GitHub until they are revoked. Once `herdquay doctor --network` passes with the
App:

1. Remove HerdQuay's SSH authentication key from the account: `gh ssh-key list`, then
   `gh ssh-key delete <id>` for the HerdQuay key, or Settings → SSH and GPG keys.
2. Revoke the fine-grained token, if one was created: Settings → Developer settings → Personal
   access tokens → Fine-grained tokens → delete.
3. Check that the old credentials fail, before deleting the local copies in the next step (skip a
   credential that never existed). With no user config, no agent and only the retired key, so
   that no other identity can authenticate instead, this answers
   `Permission denied (publickey)`:

   ```bash
   ssh -F /dev/null -o IdentityAgent=none -o IdentitiesOnly=yes -i <old key> -T git@github.com
   ```

   and this returns 401:

   ```bash
   curl -fsS -H "Authorization: Bearer <old token>" https://api.github.com/user
   ```

4. Retire the copies: delete the private key and token files wherever they were generated or
   kept (the desktop, `local/secrets/github_ssh_key` and `github_token`), and any old
   `github_ssh_key` or `github_token` secret of the deployment (`docker secret rm`).

## Recovery

| Problem | Fix |
| --- | --- |
| The host key changed unexpectedly | stop: a new key means the home volume was replaced. If intended, remove the old `known_hosts` entry and compare the new fingerprint from the logs |
| Locked out (lost the authorized key) | update the authorized keys secret and restart; the file is rebuilt on every start |
| Git or `gh` fails with "the GitHub App is not installed on …" | add the repository to the App's installation |
| Git or `gh` fails to mint a token (HTTP 401) | the App key or `HERDQUAY_GITHUB_APP_ID` is wrong, or the key was deleted in the App's settings: generate a new key, update the secret, restart |
| Claude asks to log in again | `/login` in a pane; the credentials live in `~/.claude/.credentials.json` on the home volume |
| Claude Code is missing or older than the image's version | the start log says why; restart, or run `herdquay-claude-install` in a shell |
| Rust is missing or older than the image's minimum | the start log says why; restart, or run `herdquay-rust-install` in a shell |
| An update broke Claude Code or opencode | `claude install <version>` or `opencode upgrade <version>` for a working one at or above the image's; below it, a restart puts the image's back. Removing `~/.local/bin/claude` or `~/.opencode/bin/opencode` and restarting reinstalls the image's |
| A conversation did not come back | `herdquay doctor` names it; `claude --resume <id>` in its directory |
| Herdr's native restore stops working after an upgrade | set `resume_agents_on_restore = false` in `~/.config/herdr/config.toml` and `HERDQUAY_AGENT_RESTORE=1` |
| Start from scratch | remove the home volume: a new host key, a new Claude login and an empty Herdr layout |
