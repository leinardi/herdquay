# Security model

HerdQuay gives an AI agent a shell with the owner's GitHub access. This page says what it can
reach, what protects the rest, and which risks are accepted on purpose.

## Boundaries

- **No root at run time.** Every process, sshd included, runs as UID 568. sshd runs without PAM
  and can only log in its own user. There is no sudo, no setuid helper the image relies on, and
  the harness drops every capability (`cap_drop: ALL`, `no-new-privileges`).
- **No Docker socket**, no read-write Docker API, no host filesystem mount. The Docker CLI is
  installed but has no daemon ([docker-diagnostics.md](docker-diagnostics.md)).
- **SSH**: keys only, one user, the authorized keys rebuilt from a secret on every start (removing
  a key from the secret revokes it at the next restart). No published web port. Network reach is
  for the deployment to restrict ([deployment-requirements.md](deployment-requirements.md)).
- **Remote Control** uses outbound HTTPS to Anthropic; nothing listens for it.

## Secrets

| Secret | Where it lives | Who can read it |
| --- | --- | --- |
| Authorized SSH keys | `/run/secrets/authorized_keys` | public keys; UID 568 |
| GitHub SSH private key | `/run/secrets/github_ssh_key` | UID 568 |
| GitHub fine-grained token | `/run/secrets/github_token` | UID 568 |
| Claude login | `~/.claude/.credentials.json` (0600) on the home volume | UID 568 |
| SSH host key | `~/.ssh/host/` (0600) on the home volume | UID 568 |

- None of them is in the image, a build argument, a label or Git, and none is passed as an
  environment variable, so `docker inspect` (and any Docker API proxy that allows it) cannot show
  them. In Swarm the secrets are files on a tmpfs; the API only exposes their metadata.
- `gh` reads the token from the file into `GH_TOKEN` for its own process only (the `gh` wrapper),
  so it is never written to `~/.config/gh/hosts.yml` or exported to every shell. Git's HTTPS
  credential helper goes through the same wrapper.
- The GitHub SSH key has no passphrase: HerdQuay must push while the desktop is offline, from a
  conversation driven from the phone, and nothing could unlock a passphrase then. Agent
  forwarding cannot replace it either: Herdr never forwards an agent, so Claude's panes would not
  see one. Forwarding stays allowed for manual `ssh -A` sessions.
- Locally, non-Swarm Compose ignores a secret's uid and mode, so `scripts/local-secrets.sh` grants
  UID 568 read access with a POSIX ACL instead of loosening the file mode, and checks the
  effective ACL.

## Accepted risks

- **Account-wide Git access over SSH.** The GitHub SSH key is an authentication key on the owner's
  own account, so Git over SSH can push to every repository the account can. The token's
  repository scope limits only `gh` and API calls; any process running as 568, Claude included,
  can bypass it through SSH. Mitigations: the key is HerdQuay's alone and revocable on its own in
  the GitHub settings, and rotation is a secret update plus a restart. Upgrade path, if the scope
  matters later: a machine account that collaborates only on selected repositories, or per-repo
  deploy keys.
- **The agent can use every credential.** Anything that runs as 568 can read the secrets above,
  including code Claude runs and project scripts it executes. This is inherent to an agent that
  can push. Keep the token fine-grained (selected repositories, only the permissions needed:
  contents, pull requests, issues, actions, workflows).
- **Claude credentials at rest.** `~/.claude/.credentials.json` is plaintext on the home volume,
  protected by its mode and the dataset's permissions. `/logout` and revoking the session in the
  claude.ai settings invalidate it.
- **`/tmp` allows execution.** Toolchains (`go test`, Playwright, pre-commit) run binaries from
  `/tmp`, so its tmpfs is mounted `exec` (still `nosuid,nodev`).

## Supply chain

The base is `ubuntu:26.04`, pinned by tag so the official image's security rebuilds are picked
up. Every other download is pinned by version and verified before use: Claude Code
against its GPG-signed release manifest (Anthropic's key vendored in `container/keys/`, its
fingerprint pinned), the release binaries and toolchains against their published SHA-256 digests,
and the Docker CLI against Docker's apt key fingerprint. GitHub's SSH host keys are shipped in
`/etc/ssh/ssh_known_hosts` and checked against GitHub's published fingerprints; a changed GitHub
host key fails the connection instead of prompting. See [updating.md](updating.md).
