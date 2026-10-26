# Development environment

HerdQuay carries the toolchains of the owner's current projects, chosen from their manifests,
Makefiles, pre-commit configs and CI workflows: swarm-device-access (SDA), monmux,
awtrix-controller, bitgauge and runhold. Shared toolchains are installed once; project
dependencies stay in the projects (Go modules, `npm ci`, pre-commit hook environments,
Playwright browsers), cached in the home volume.

## Dependency matrix

| Need | SDA | monmux | awtrix | bitgauge | runhold | Provided by |
| --- | --- | --- | --- | --- | --- | --- |
| Go 1.26 (floor 1.26.9) | ✓ | ✓ |  | ✓ | ✓ | image: Go 1.26.10; `GOTOOLCHAIN=auto` for a module that asks for more |
| gcc, libc headers (`-race`, cgo tests) | ✓ | ✓ | ✓ | ✓ | ✓ | image: `build-essential`, `pkg-config` |
| make, git, bash, curl, coreutils | ✓ | ✓ | ✓ | ✓ | ✓ | image |
| Node 24 + npm (lockfile v3) |  |  |  | ✓ | ✓ | image: Node 24.22.1; `npm ci` per project; `npm i -g` goes to `~/.local` |
| Python 3 + venv | ✓ | ✓ | ✓ | ✓ | ✓ | image: Python 3.14 (pre-commit, Herdr's hook, `http.server`) |
| pre-commit 4.6.2 | ✓ | ✓ | ✓ | ✓ | ✓ | image; hook environments in `~/.cache/pre-commit` |
| Rust (rustup, `cargo`) | droast hook |  | ✓ 1.98.0 (`rust-toolchain.toml`) | droast hook | droast hook | home volume: `herdquay-rust-install` puts rustup and the stable toolchain (minimum 1.99.1) there at start; `rust-toolchain.toml` channels install on first use; cargo tools such as awtrix's `cargo-deny` per user, `cargo install --locked` into `~/.cargo/bin` |
| droast 1.7.0 | ✓ hook, label test |  | ✓ hook, label test | ✓ hook | ✓ hook | the hooks build their own with `cargo`; image: the binary the label tests run |
| ShellCheck 0.11.0 on PATH (droast's bridge) | ✓ |  | ✓ | ✓ | ✓ | image |
| golangci-lint 2.14.0 on PATH | hook | ✓ `go-lint-cross` |  | hook | hook | image |
| goreleaser 2.18.1 (`check`, snapshot) |  | ✓ |  |  |  | image |
| Playwright 1.64.0: Chromium, Firefox, WebKit |  |  |  | ✓ e2e, parity | ✓ screenshots | image: the three browsers' system libraries; browsers per project in `~/.cache/ms-playwright` |
| govulncheck, sqlc, svu, actionlint, checkmake, dclint | ✓ | ✓ | ✓ | ✓ | ✓ | per project: `go run …@version`, pre-commit hook environments (dclint's Node 22 included) |
| Docker CLI, buildx, Compose | ✓ |  | ✓ | ✓ | ✓ | image, client; a daemon only as the opt-in rootless one ([docker-diagnostics.md](docker-diagnostics.md)) |
| trivy | CI |  | CI | CI | CI | not in the image: CI only |

No toolchain manager: one Go and one Node cover all five projects today, and a manager would be
one more moving part. Revisit if two projects need different lines at once.

Next to Claude Code, the image has opencode 2.1.4 as a minimum: it is copied into
`~/.opencode/bin` and updates itself from there, like Claude Code
([operations.md](operations.md#claude-code-at-first-start)).
Rust is in the home volume too: rustup and the stable toolchain, installed at start with 1.99.1
as the minimum and upgraded with `rustup update` ([operations.md](operations.md#rust)).

It also has the CLI tools an agent or a GitHub runner usually has: `gh`, `chezmoi`, `jq`, `yq`,
`rg`, `fd`, `tree`, `wget`, `zip`/`unzip`/`xz`/`zstd`, `rsync`, `file`, `bc`, `gawk`, `sqlite3`,
`dig`, `nc`, `ping`, `lsof`, `htop`, `strace`, `openssl`, `gpg`, `git-lfs`, `vim`, `nano`,
`patch`.

## Validated workflows

`tests/projects.sh` (`make projects-test`, manual, with network) copies each checkout into the
running container's workspace volume and runs, as UID 568:

| Project | Commands | Result (2026-10-23) |
| --- | --- | --- |
| swarm-device-access | `make verify-go`, `make check` | pass |
| monmux | `make check`, `make go-lint-cross`, `goreleaser check`, `goreleaser release --snapshot --clean --skip=publish,sign` | pass |
| awtrix-controller | `make verify`, `make check` | pass |
| bitgauge | `make web-install web-build verify`, `playwright install`, `make e2e` | pass: 1602 unit tests, 171 end-to-end tests over the three browsers |
| runhold | `make web-install web-build verify-go verify-web` | pass |

Re-run on 2026-10-25, after the move from hadolint to droast and Rust in the home volume:
awtrix-controller, now in Rust (`make verify`, then `make check` after
`cargo install --locked cargo-deny`), and swarm-device-access (`make verify-go`, `make check`, with
`SDA_REQUIRE_TOOLS=1` so the droast label test cannot skip) both pass.

## What does not run in HerdQuay

| Workflow | Projects | Why |
| --- | --- | --- |
| `docker-build`, `integration-image`, `go-test-image`, `harness-*` image builds | SDA, awtrix, bitgauge, runhold | no Docker daemon by default; with the opt-in rootless daemon, not validated yet. Their bases also need a dhi.io login |
| `go-test-integration` with enforcement, `docker-run` | SDA | loads BPF programs and touches host cgroups and loop devices: CAP_BPF/CAP_SYS_ADMIN, host PID and cgroup namespaces |
| `go-test-integration` (DinD), `lab-*`, `run` / `docker-run-agent` | runhold | privileged Docker-in-Docker, Swarm init, a Docker socket |
| `go-test-integration-vm` | runhold | multipass / KVM |
| `harness-*` network shaping and measurements | bitgauge | host kernel modules (`ifb`, `sch_netem`, …), and per-container cgroups the rootless daemon does not have |
| Release signing and publishing | all | GitHub OIDC and registry credentials: CI only |
| Real `ddcutil` / I²C | monmux | hardware, and forbidden for agents by monmux's own rules |

A fresh checkout of bitgauge or runhold needs `make web-build` before the Go targets: both
embed the built web UI.
