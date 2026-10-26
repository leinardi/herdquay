# HerdQuay core

Docker image: persistent remote AI coding env (unprivileged sshd on 2222, headless Herdr server, Claude Code, opencode, git, gh, toolchains). Repo scope = image, local Compose harness, tests, docs. Deployment to the owner's homelab lives in a separate private `homelab` repo: never change it from here; `docs/deployment.md` is the generic contract. `README.md` is the user-facing contract; keep it in step.

Source map:
- `Dockerfile`: `fetch` stage downloads + verifies every non-apt artifact; final stage same `ubuntu:26.04` base. Narrow `chmod -R go-w` list (dirs, not files).
- `container/bin/` -> `/usr/local/bin`: `herdquay-entrypoint` (tini child; supervises sshd + `herdr server`), `herdquay` (doctor), `herdquay-agents`, `herdquay-healthcheck`, `herdquay-claude-install` (Claude installed at first start into the home volume, never shipped; pin is a minimum, Claude self-updates; opencode likewise seeded into `~/.opencode/bin` by the entrypoint), `herdquay-github` (GitHub App tokens + git credential helper), `herdquay-gpg` (signing keyring on tmpfs), `gh` wrapper (real gh at `/opt/gh/bin/gh`).
- `container/etc/` -> `/etc`: sshd_config, system gitconfig (credential helper, HTTPS insteadOf rewrites, include of `~/.config/herdquay/identity.gitconfig`).
- `compose.yaml` + optional `compose.github.yaml` overlay (added by `.mk/image.mk` when `local/secrets/github_app_key` exists).
- `scripts/local-secrets.sh`: harness secrets in ignored `local/secrets/`, ACL-granted to UID 568.
- `tests/`: `smoke.sh`, `supervision.sh` (CI), `projects.sh` (manual), `lib.sh`, `github-stub.py`.

Invariants:
- No secret ever in image, build args, labels, env vars or Git; secrets only as files under `/run/secrets/` at run time.
- No root at run time; everything runs as UID:GID 568:568. No Docker socket, never a read-write path to the host's Docker daemon; the only daemon is an opt-in dedicated rootless one (docs/docker-diagnostics.md).
- GitHub over HTTPS only via a GitHub App; no SSH key/ssh_config for GitHub. Token cache and GPG keyring only in `/dev/shm` (RAM under every orchestrator; Swarm leaves `/tmp` on disk and ignores `no-new-privileges`, so the image carries no setuid/setgid/file-cap binary).
- SSH sessions do not inherit the container env: the entrypoint writes `~/.config/herdquay/github.env` (paths/IDs, never keys) at every start; scripts fall back to it. The Docker endpoint (`DOCKER_HOST`, `DOCKER_TLS_VERIFY`, `DOCKER_CERT_PATH`) goes to `~/.ssh/environment`, read by sshd's `PermitUserEnvironment` allow-list (keep it in step with `SESSION_ENV_NAMES` in the entrypoint).
- Every download pinned and verified (checksum/signature).

More: stack and pins `mem:tech_stack`; commands `mem:suggested_commands`; code/commit style `mem:conventions`; definition of done `mem:task_completion`.
