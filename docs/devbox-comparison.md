# Comparison with rozsival/devbox

[rozsival/devbox](https://github.com/rozsival/devbox) (MIT) is the reference HerdQuay started
from: one container with an unprivileged sshd that a laptop's Herdr client attaches to. HerdQuay
keeps its core ideas and drops what belongs to its author's environment. `sshd_config` is adapted
from devbox and credits it in its header; nothing else is copied.

| devbox | HerdQuay | Verdict and why |
| --- | --- | --- |
| Ubuntu 26.04 base | `ubuntu:26.04`, pinned by tag | **adopted**: the owner's desktop release too, and close to GitHub's runners. A DHI Debian 13 (`dhi.io/debian-base:trixie-dev`) base was built and tested first; it worked, but its hardening mostly goes unused in a 2.6 GB workstation, while it needed a dhi.io login everywhere (locally, CI, Dependabot) and mixes DHI's and Debian's apt repositories |
| sshd run by the dev user on 2222, no PAM, keys only, `StrictModes`, `MaxSessions 32`, client-alive | same | **adopted**: no root at run time; Herdr multiplexes many channels over one connection |
| `useradd` with the host's UID/GID, the stock `ubuntu` user removed | the same, UID:GID 568:568 by build arg, password field `*` | **adapted**: matches the homelab's apps user; useradd's locked `!` would make sshd refuse even a key |
| tini as PID 1, entrypoint that `exec`s sshd | tini, and an entrypoint that supervises sshd and `herdr server`, exits non-zero when either dies, stops both within a bound | **adapted**: the Herdr server must run before any client attaches, so that conversations resume unattended |
| herdr in `/usr/local/bin`, pinned, checked against the release asset digest | same | **adopted**: Herdr's background SSH only uses a binary already on the PATH |
| Host key on the persistent home, generated once | same | **adopted** |
| `authorized_keys` rebuilt on start from `github.com/<user>.keys` | rebuilt on start from a secret file, fail closed | **adapted**: no network fetch at start, the deployment controls the list |
| Claude Code installed at run time by `install.sh`, self-updating | installed at run time too, into the same layout, but at the version the image pins as a minimum, its manifest's GPG signature and checksum verified; self-updating from there | **adapted**: not redistributed in the image, and `install.sh` does not check the signature |
| Launcher that unsets `ANTHROPIC_API_KEY` | not needed: no API key is ever passed in | **simplified**: Remote Control requires the claude.ai login anyway |
| No Remote Control configuration | `remoteControlAtStartup: true` seeded, Herdr's native restore on, `herdquay-agents verify` | **added**: the phone must reach the same live conversations, also after a restart |
| Per-identity Git config, GitHub App tokens (`devbox-git-credential`), `gh` shim per directory | one GitHub App: `herdquay-github`, adapted from `devbox-git-credential`, mints a token per repository for Git and an installation-wide one for the `gh` wrapper, cached on tmpfs; one commit identity (the environment's or the App's bot); no SSH to GitHub | **adapted**: one owner and one App, so no per-directory identities |
| Healthcheck: `ss` on 2222 | `ss` on 2222 and the Herdr server answering | **adapted** |
| `devbox doctor` scripts as acceptance tests, no CI | `herdquay doctor`, plus automated smoke and supervision tests in CI | **adapted** |
| One bind-mounted home | a home volume and a separate workspace volume | **adapted**: separate snapshot policies on TrueNAS |
| Tailscale bind address, 1Password SSH agent, Moshi, OMP, Vercel/Neon guardrails, laptop doctor | none | **omitted**: the author's environment; HerdQuay sits behind pfSense and WireGuard |
| Rootless sibling Docker daemon, socat port mirrors | Docker CLI only by default; optionally a dedicated rootless daemon in its own container, checked by `herdquay doctor`; no port mirrors, no published ports besides SSH | **adapted**: an opt-in of the deployment, never shared ([docker-diagnostics.md](docker-diagnostics.md)) |
| nvm, terraform, lazygit, worktrunk, starship | Node from a pinned tarball; the projects' toolchains ([dev-environment.md](dev-environment.md)) | **replaced or omitted** |

## Findings that devbox does not cover

- **Herdr saved machines need a session-leader server.** Herdr only accepts a remote server as a
  saved machine if it is a "detached daemon" (`getsid(0) == getpid()`). Starting `herdr server`
  as an ordinary child fails `herdr machine add` with "remote server is not ready for saved
  machines"; the entrypoint starts it with `setsid`, which keeps the same PID under supervision.
- **Native restore works with no client attached.** Herdr's session-state docs say restored agent
  panes resume after a client attaches. With the headless `herdr server` (0.9.5) they resume with
  zero connections, so Remote Control comes back without the desktop. HerdQuay relies on it and
  checks it (`herdquay-agents verify`), with an active fallback (`HERDQUAY_AGENT_RESTORE=1`).
- **Herdr's Claude hook needs Python.** Without `python3` the integration never reports the
  session id, and nothing can be resumed.
