# Deployment requirements

What the later homelab deployment (Ansible, Docker Swarm on TrueNAS, in the `homelab` repository)
must provide. Nothing here is implemented yet; the values were checked against `homelab/` on
2026-10-23.

## Service

- One replica, `restart_policy: any`, `stop_grace_period: 30s` (above `HERDQUAY_STOP_TIMEOUT`,
  15 s by default).
- **Placement `node.role == manager`**: the swarm is not single-node. Pollux joins it as a worker
  when it is awake, and the persistent datasets live on Castor.
- `cap_drop: ALL`, no `privileged`, no added capabilities, no host network or PID namespace,
  no Docker socket. `user` is the image's own 568:568 (do not override it).
- `/tmp` as a tmpfs **with `exec`** (`nosuid,nodev` kept): Go tests, Playwright and pre-commit run
  binaries from it, and Docker mounts a tmpfs `noexec` by default.
- The image: published to GHCR by a release workflow that comes with the deployment (the homelab
  host has no ghcr.io login, so the package must be public or the host needs a pull credential).
- Logging: the homelab's fluentd convention is fine; the container logs to stdout/stderr.

## Persistence

| Mount | Content | Dataset |
| --- | --- | --- |
| `/home/herdquay` | Claude login and history (`~/.claude/`, `~/.claude.json`), Herdr state (`~/.config/herdr/`), SSH host key (`~/.ssh/host/`), Git config, toolchain caches (`~/go`, `~/.cache`, `~/.npm`, Playwright browsers) | its own dataset, owned 568:568, mode 0750 |
| `/home/herdquay/workspace` | the repositories | its own dataset, owned 568:568, so it can have its own snapshot policy |

No other NAS dataset is mounted. The home dataset holds credentials (Claude, the host key): keep
it out of shares and replicate it only to trusted targets.

## Secrets

| Swarm secret | Target | Source |
| --- | --- | --- |
| authorized keys | `/run/secrets/authorized_keys` | the desktop and VPN client public keys (Ansible vars) |
| GitHub SSH key | `/run/secrets/github_ssh_key` | **created by hand, not in the Vault**: an ed25519 key without a passphrase, generated on the desktop, its public key added to GitHub; `docker secret create herdquay_github_ssh_key <file>` on the manager, then the local copy deleted; referenced as `external: true` |
| GitHub token | `/run/secrets/github_token` | **created by hand, not in the Vault**: `docker secret create herdquay_github_token -` on the manager, from stdin; referenced as `external: true` |

Neither GitHub credential passes through Ansible or any repository: Ansible only references the
two secret names, so a deployment without them fails to start instead of running without
GitHub access.

Each with `uid: "568"`, `gid: "568"`, `mode: 0400`. Rotation: a new versioned secret name, update
the reference, redeploy, delete the old one.

Environment: `HERDQUAY_GIT_NAME`, `HERDQUAY_GIT_EMAIL`. Never pass a credential as an environment
variable.

## Network

- Publish **only port 2222**, reachable from the TRUSTED VLAN (10.10.10.0/24) and the authorized
  WireGuard admin peers (tunnel 172.22.222.0/24), enforced on pfSense. No HAProxy or Traefik
  route, no WAN exposure. Note that ingress-mode ports bypass pfSense for anything already on
  the same VLAN as the NAS; host mode on the manager keeps the source address visible if a
  per-source rule is wanted.
- Outbound HTTPS is required: Anthropic (Claude, Remote Control), GitHub (SSH 22 and HTTPS),
  the Go module proxy, npm, PyPI, nodejs.org, Playwright's CDN. Attach it to the existing
  `swarm_internet` overlay, or an equivalent egress network.
- No other overlay: in particular, not `docker_api_ro` or `docker_api_rw`.

## Optional Docker diagnostics

A separate decision ([docker-diagnostics.md](docker-diagnostics.md)): a dedicated read-only
proxy instance on its own internal network, with an explicit endpoint list, and
`DOCKER_HOST=tcp://<proxy>:2375` in HerdQuay. The existing `ro` proxy's `LOGS=0` does not block
logs, and the read-write proxy is never an option.

## Acceptance after deployment

1. `ssh` from TRUSTED with the host key fingerprint logged at first start; refused from other
   VLANs.
2. `herdquay doctor --network` passes (GitHub over SSH and with the token).
3. Herdr on the desktop attaches; a Claude conversation shows on the phone; detach, still there.
4. `docker service update --force`: the conversation resumes on the phone with no desktop
   attached; `herdquay doctor` reports every session resumed.
