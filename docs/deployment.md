# Deployment

What any deployment of the image (Docker Swarm, Compose, another orchestrator) must provide. The
local harness, `compose.yaml`, is a working reference for all of it except the orchestrator's
own secret handling.

## Service

- The image `ghcr.io/leinardi/herdquay:<version>`, public, so no registry login is needed. Pin a
  version (or its digest), not `:latest`, and verify it as [release.md](release.md) shows.
- One replica: the home volume holds a single Herdr server's state.
- A restart policy that restarts the container when it exits non-zero: the entrypoint exits 1
  when sshd or the Herdr server dies, and 0 on a requested stop.
- A stop grace period above `HERDQUAY_STOP_TIMEOUT` (15 s by default), for example 30 s, so the
  entrypoint stops both children and Herdr saves its session before the runtime's SIGKILL.
- `cap_drop: ALL`, no `privileged`, no added capabilities, no host network or PID namespace, no
  Docker socket. Keep the image's user, 568:568 (`HERDQUAY_UID`/`HERDQUAY_GID` at build time).
- `/tmp` as a tmpfs **with `exec`** (`nosuid,nodev` kept): Go tests, Playwright and pre-commit run
  binaries from it, and Docker mounts a tmpfs `noexec` by default.
- The image has a `HEALTHCHECK` (sshd listening on 2222, the Herdr server answering), with a
  6-minute start period that covers the first start's Claude Code download, and logs to
  stdout/stderr.

## Persistence

| Mount | Content |
| --- | --- |
| `/home/herdquay` | Claude Code itself (`~/.local/share/claude/`, installed at first start), its login and history (`~/.claude/`, `~/.claude.json`), opencode logins (`~/.local/share/opencode/`), Herdr state (`~/.config/herdr/`), the SSH host key (`~/.ssh/host/`), Git config, toolchain caches (`~/go`, `~/.cache`, `~/.npm`, Playwright browsers) |
| `/home/herdquay/workspace` | the repositories: a volume of its own, so it can have its own snapshot or backup policy |

Both owned by 568:568. The home volume holds credentials (Claude, opencode, the host key): keep it
private and back it up only to trusted targets.

## Secrets

| Secret file | Required | Content |
| --- | --- | --- |
| `/run/secrets/authorized_keys` | yes | the public keys allowed to log in; the container refuses to start without it |
| `/run/secrets/github_app_key` | no | the GitHub App's private key, for Git and `gh` over HTTPS ([operations.md](operations.md#github-app) sets the App up, [security.md](security.md) explains the trade-offs) |
| `/run/secrets/git_signing_key` | no | an armored GPG secret key without a passphrase, to sign commits as `HERDQUAY_GIT_NAME` / `HERDQUAY_GIT_EMAIL` ([operations.md](operations.md#commit-signing)) |

Each readable by UID 568 only (in Swarm: `uid: "568"`, `gid: "568"`, `mode: 0400`). Prefer
creating the GitHub ones by hand on the host (`docker secret create … -` from stdin) over keeping
them in a deployment repository. Rotation: a new secret name, update the reference, redeploy,
delete the old one.

Environment: `HERDQUAY_GITHUB_APP_ID`, required with the App key; `HERDQUAY_GIT_NAME` and
`HERDQUAY_GIT_EMAIL`, both or neither, for the commit identity (default: the App's bot). Never pass
a credential as an environment variable: `docker inspect` shows them.

## Network

- Publish **only port 2222** (SSH), and only to the networks the desktop and phone-side admin
  clients connect from. HerdQuay needs no inbound HTTP and should have no reverse-proxy route or
  internet exposure.
- Outbound HTTPS is required: Anthropic (Claude Code's download at first start, Claude, Remote
  Control), GitHub (HTTPS only: `github.com`, `api.github.com`; no SSH), the Go module proxy, npm,
  PyPI, nodejs.org, Playwright's CDN, and the providers opencode is logged in to.
- No Docker API network by default ([docker-diagnostics.md](docker-diagnostics.md)).

## Acceptance after deployment

1. `ssh` works from the allowed networks, with the host key fingerprint logged at first start,
   and is refused from anywhere else.
2. `herdquay doctor --network` passes (an App installation token, a repository listed with `gh`,
   `git ls-remote` over HTTPS).
3. Herdr on the desktop attaches; a Claude conversation shows on the phone; detach, still there.
4. Restart the container: the conversation resumes on the phone with no desktop attached, and
   `herdquay doctor` reports every session resumed.
