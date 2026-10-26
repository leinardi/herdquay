# Development environment

HerdQuay carries the toolchains of typical Go, Node, Python, Rust, OpenTofu and GNOME extension
projects, with the linters and release tools their Makefiles, pre-commit configs and CI workflows
usually run. Shared toolchains are installed once; project dependencies stay in the projects (Go
modules, `npm ci`, pre-commit hook environments, Playwright browsers), cached in the home volume.

## Toolchains

| Need | Provided by |
| --- | --- |
| Go 1.26 | image: Go 1.26.10; `GOTOOLCHAIN=auto` for a module that asks for more |
| gcc, libc headers (`-race`, cgo tests) | image: `build-essential`, `pkg-config` |
| make, git, bash, curl, coreutils | image |
| Node 24 + npm (lockfile v3) | image: Node 24.22.1; `npm ci` per project; `npm i -g` goes to `~/.local` |
| Python 3 + venv | image: Python 3.14 (pre-commit, Herdr's hook, `http.server`) |
| pre-commit 4.6.2 | image; hook environments in `~/.cache/pre-commit` |
| Rust (rustup, `cargo`) | home volume: `herdquay-rust-install` puts rustup and the stable toolchain (minimum 1.99.1) there at start; `rust-toolchain.toml` channels install on first use; other cargo tools per user, `cargo install --locked` into `~/.cargo/bin` |
| cargo-deny 0.20.2 (`cargo deny check`) | image: on PATH, so `cargo deny` finds it without a per-user install |
| droast 1.7.0 | image, for tests that run it directly; pre-commit hooks build their own with `cargo` |
| ShellCheck 0.11.0 on PATH (droast's bridge) | image |
| golangci-lint 2.14.0 on PATH | image |
| goreleaser 2.18.1 (`check`, snapshot) | image |
| Playwright 1.64.0: Chromium, Firefox, WebKit | image: the three browsers' system libraries; browsers per project in `~/.cache/ms-playwright` |
| govulncheck, sqlc, svu, actionlint, checkmake, dclint | per project: `go run …@version`, pre-commit hook environments |
| Docker CLI, buildx, Compose | image, client; a daemon only as the opt-in rootless one ([docker-diagnostics.md](docker-diagnostics.md)) |
| OpenTofu 1.13.2 (`tofu fmt`, `tofu validate`) | image |
| TFLint 0.65.0 | image; its plugins per user, `tflint --init` into `~/.tflint.d` |
| terraform-docs 0.22.0 | image |
| Trivy 0.76.1 | image; its vulnerability database per user, in `~/.cache/trivy` |
| GNOME extensions: `gjs`, `glib-compile-schemas`, gettext (`xgettext`, `msgfmt`, `msgmerge`) | image: `gjs`, `libglib2.0-bin`, `gettext`; no GNOME Shell, so no `gnome-extensions pack` and no interactive Shell testing |

No toolchain manager: one Go and one Node line are enough today, and a manager would be one more
moving part. Revisit if two projects need different lines at once.

Next to Claude Code, the image has opencode 2.1.4 as a minimum: it is copied into
`~/.opencode/bin` and updates itself from there, like Claude Code
([operations.md](operations.md#claude-code-at-first-start)).
Rust is in the home volume too: rustup and the stable toolchain, installed at start with 1.99.1
as the minimum and upgraded with `rustup update` ([operations.md](operations.md#rust)).

It also has the CLI tools an agent or a GitHub runner usually has: `gh`, `chezmoi`, `uv`, `jq`,
`yq`, `rg`, `fd`, `tree`, `wget`, `zip`/`unzip`/`xz`/`zstd`, `rsync`, `file`, `bc`, `gawk`,
`sqlite3`, `setfacl`/`getfacl`, `dig`, `nc`, `ping`, `lsof`, `htop`, `strace`, `openssl`, `gpg`,
`git-lfs`, `tig`, `vim`, `nano`, `patch`.

`uv` (and `uvx`) installs Python tools into the home volume, where they persist: `uv tool install`
puts them in `~/.local/bin`, and a Python version they need other than the image's 3.14 in
`~/.local/share/uv`.

## What does not run in HerdQuay

| Workflow | Why |
| --- | --- |
| Image builds and image-based tests | no Docker daemon by default; the opt-in rootless one has the limits [docker-diagnostics.md](docker-diagnostics.md) lists |
| BPF programs, host cgroups, loop devices | CAP_BPF/CAP_SYS_ADMIN, host PID and cgroup namespaces |
| Docker-in-Docker, Swarm, a Docker socket | privileged containers |
| VMs (multipass, KVM) | no `/dev/kvm` |
| Network shaping (`ifb`, `sch_netem`, …) | host kernel modules |
| Release signing and publishing | GitHub OIDC and registry credentials: CI only |
| Hardware access (I²C, USB devices) | no devices are passed in |

POSIX ACLs (`setfacl`) work only where the filesystem supports them. The container's `/tmp`
(overlayfs, or a tmpfs) usually does; a workspace on a ZFS dataset with NFSv4 ACLs does not, so
with `HERDQUAY_WORKSPACE_TMP=1` a test that sets ACLs under `TMPDIR` fails there. Run such a test
with `TMPDIR=/tmp`.
