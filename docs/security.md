# Security model

HerdQuay gives an AI agent a shell with GitHub access, as a GitHub App installed on the owner's
repositories. This page says what it can
reach, what protects the rest, and which risks are accepted on purpose.

## Boundaries

- **No root at run time.** Every process, sshd included, runs as UID 568. sshd runs without PAM
  and can only log in its own user. There is no sudo, and the image carries no setuid or setgid
  binary and no file capability (they are stripped at build time, and the smoke test checks it),
  so nothing can raise a process's privileges even where `no-new-privileges` is not applied:
  Docker Swarm ignores `security_opt`. Every capability is dropped (`cap_drop: ALL`, which Swarm
  honours), and the harness adds `no-new-privileges` too.
- **No Docker socket**, no access to the host's Docker daemon, no host filesystem mount. The
  Docker CLI has no daemon unless the deployment adds a dedicated rootless one, whose escape lands
  on an unprivileged host user; `herdquay doctor` fails any daemon that is not rootless
  ([docker-diagnostics.md](docker-diagnostics.md)).
- **SSH**: keys only, one user, the authorized keys rebuilt from a secret on every start (removing
  a key from the secret revokes it at the next restart). Sessions get none of the container's
  environment except the Docker endpoint and what goes with it: `PermitUserEnvironment` allows
  only `DOCKER_HOST`, `DOCKER_TLS_VERIFY`, `DOCKER_CERT_PATH`, `HERDQUAY_DOCKER_HOSTNAME`, the two
  `TESTCONTAINERS_*` overrides, `TMPDIR` and `CLAUDE_CODE_TMPDIR` from `~/.ssh/environment`, which
  the entrypoint writes, and the client can send only the locale and terminal variables. No
  published web port. Network reach is for the deployment to restrict ([deployment.md](deployment.md)).
- **Remote Control** uses outbound HTTPS to Anthropic; nothing listens for it.

## Secrets

| Secret | Where it lives | Who can read it |
| --- | --- | --- |
| Authorized SSH keys | `/run/secrets/authorized_keys` | public keys; UID 568 |
| GitHub App private key | `/run/secrets/github_app_key` | UID 568 |
| GitHub installation tokens (one hour) | `/dev/shm/herdquay-github` (RAM, directory 0700, files 0600) | UID 568 |
| Git signing key (optional) | `/run/secrets/git_signing_key`; imported into `/dev/shm/herdquay-gnupg` (RAM, 0700) | UID 568 |
| Claude login | `~/.claude/.credentials.json` (0600) on the home volume | UID 568 |
| opencode provider logins | `~/.local/share/opencode/auth.json` on the home volume | UID 568 |
| SSH host key | `~/.ssh/host/` (0600) on the home volume | UID 568 |

- None of them is in the image, a build argument, a label or Git, and none is passed as an
  environment variable, so `docker inspect` (and any Docker API proxy that allows it) cannot show
  them. In Swarm the secrets are files on a tmpfs; the API only exposes their metadata.
- The installation tokens are minted from the App key by `herdquay-github`: Git's credential
  helper gets one restricted to the repository it is working on, and `gh` gets an
  installation-wide one in `GH_TOKEN` for its own process only (the `gh` wrapper). None is ever
  written to the home volume, `~/.config/gh/hosts.yml` or an exported variable.
- The App key has no passphrase: HerdQuay must push while the desktop is offline, from a
  conversation driven from the phone, and nothing could unlock a passphrase then. Agent
  forwarding cannot replace it either: Herdr never forwards an agent, so Claude's panes would not
  see one. Forwarding stays allowed for manual `ssh -A` sessions.
- There is no SSH key for GitHub: GitHub is reached over HTTPS only, and SSH remote URLs are
  rewritten to HTTPS. Credentials from before the App (an SSH key on the account, a fine-grained
  token) must be **revoked** on GitHub, not just unmounted: they keep working until then
  ([operations.md](operations.md#upgrading-from-the-ssh-key)).
- Locally, non-Swarm Compose ignores a secret's uid and mode, so `scripts/local-secrets.sh` grants
  UID 568 read access with a POSIX ACL instead of loosening the file mode, and checks the
  effective ACL.

## Accepted risks

- **The App's reach, with its private key in the container.** The key mints tokens for every
  repository of the App's installation, with the App's permissions (contents, pull requests,
  issues and workflows read and write, actions read), for as long as the key is valid. A Git token
  is restricted to one repository and expires within the hour, but any process running as 568,
  Claude included, can read the key and mint a token for any installed repository; installed on
  "All repositories", that is every repository of the account, future ones included. Mitigations:
  the permissions are the minimum, an installation on "Only select repositories" narrows the reach
  when that matters more than convenience, and the key is revocable on its own in the App's
  settings (or the installation suspended); rotation is a new key, a secret update and a restart.
  Later hardening: a token broker outside the container that holds the key and hands out
  per-repository tokens, so the container never sees the key.
- **The agent can use every credential.** Anything that runs as 568 can read the secrets above,
  including code Claude runs and project scripts it executes. This is inherent to an agent that
  can push. Keep the App's permissions, and its repository selection when it has one, to what
  HerdQuay needs.
- **The agent can sign as the owner.** With the optional signing key, any process running as 568,
  Claude included, can sign commits and tags as the owner, and that carries more weight than the
  push itself: GitHub shows those commits as Verified, as if the owner had made them. The key has
  no passphrase, for the same reason as the other secrets, and it never reaches the home volume
  (`herdquay-gpg` keeps the keyring on `/tmp`). Mitigations: a dedicated signing-only key with an
  expiry, used for nothing else, revocable on its own with `gh gpg-key delete`. Deleting it stops
  new signatures from verifying, but GitHub keeps the verification it recorded for commits already
  pushed, so commits signed before the deletion may stay Verified and need checking. The App's bot
  identity never signs.
- **Agent credentials at rest.** `~/.claude/.credentials.json` and opencode's
  `~/.local/share/opencode/auth.json` are plaintext on the home volume, protected by their mode
  and the dataset's permissions. `/logout` and revoking the session in the claude.ai settings
  invalidate Claude's; `opencode auth logout` and revoking the key at the provider invalidate
  opencode's.
- **Claude Code and opencode are writable by their user, and update themselves.** Both live in
  the home volume, owned by 568, so a process running as 568 could replace them, which a
  root-owned binary in the image would prevent. That process could already act as the user in
  every other way. The image's versions are verified when installed; the updates after them are
  verified only as Anthropic's and opencode's own updaters do it (over HTTPS), without the image's
  pinned signing key or integrity. Removing
  `~/.local/bin/claude` or `~/.opencode/bin/opencode` and restarting reinstalls the image's
  version.
- **`/tmp` allows execution.** Toolchains (`go test`, Playwright, pre-commit) run binaries from
  `/tmp`, so the harness mounts it as an `exec` tmpfs (still `nosuid,nodev`). Docker Swarm cannot
  mount an `exec` tmpfs, so there `/tmp` stays on the container's writable layer, on disk, cleared
  when the task is replaced. No credential lives in `/tmp`: the token cache and the signing keyring
  are in `/dev/shm`, the container's own RAM tmpfs, under every orchestrator.

## Supply chain

The base is `ubuntu:26.04`, pinned by tag so the official image's security rebuilds are picked up.
Every other download is pinned by version and verified before use: Claude Code, installed into the
home volume at first start rather than shipped in the image, against its GPG-signed release manifest
(Anthropic's key vendored in `container/keys/`, its fingerprint pinned in the image), the release
binaries and toolchains against their published SHA-256 digests, opencode against npm's SHA-512
integrity (both then update themselves, see above), and the Docker CLI against Docker's apt key
fingerprint. GitHub is reached over HTTPS only, verified against the system's CA certificates. See
[updating.md](updating.md).
