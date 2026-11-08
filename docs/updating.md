# Updating the image

Every tool is pinned in the `Dockerfile` as an `ARG`, with what verifies it. Claude Code and Rust
are the pins the image does not contain: `herdquay-claude-install` downloads and verifies Claude
Code at the first start of an image that pins a new version, and `herdquay-rust-install` installs
rustup and the stable toolchain into the home volume.

Claude Code and opencode update themselves, so they follow their daily releases without a new image.
Both live in the home volume: Claude Code in `~/.local/share/claude/versions/`, opencode in
`~/.opencode/bin/`. Their auto-updaters are on, and `claude update` and `opencode upgrade` work by
hand. For these two, the image's versions are minimums: a start keeps any installed version at or
above them, and only replaces a missing, broken or older one with the verified pinned release. The
updaters' downloads are checked only as Anthropic's and opencode's own updaters check them (over
HTTPS), not with the image's pinned signature or integrity. Everything else, Herdr included, only
changes with a new image.

Rust follows the same rule: `RUST_MINIMUM` is a floor, and `rustup update` upgrades rustup and the
toolchains in `~/.rustup` and `~/.cargo` without a new image. A start only installs the current
stable over a missing rustup or a default toolchain below the floor.

## Routine

```bash
make check-updates                          # lists every pin with a newer upstream release
# edit the ARG (and its digest) in the Dockerfile
make image-build image-test                 # smoke and supervision tests
make check                                  # droast and the rest
```

Commit the bump on its own (`fix(image): …` when it should ship). CI rebuilds the image and runs
the same automated tests, and the release relies on them ([release.md](release.md#what-ci-proves)).

## Pins

| Pin | Verified by | Where the new value comes from |
| --- | --- | --- |
| Base image (`FROM ubuntu:26.04@sha256:… AS base`) | index digest (Docker Official Image) | Dependabot's `docker` entry proposes each rebuild's digest as `fix(deps)`; by hand, the `Digest:` of `docker buildx imagetools inspect ubuntu:26.04` |
| `HERDR_VERSION`, `HERDR_SHA256` | release asset digest (Herdr publishes no checksum file or signature) | `make check-updates` prints the digest |
| `CLAUDE_VERSION` (a minimum) | GPG signature of the release manifest, then the binary's checksum in it, both at first start | the stable channel, `https://downloads.claude.ai/claude-code-releases/stable`; Claude Code updates itself in between, so bump it only to raise the floor |
| `CLAUDE_SIGNER_FINGERPRINT`, `container/keys/claude-code.asc` | pinned fingerprint | only when Anthropic rotates its release key: compare the new fingerprint with the [setup docs](https://code.claude.com/docs/en/setup) before replacing both |
| `GO_VERSION`, `GO_SHA256` | SHA-256 | `https://go.dev/dl/?mode=json&include=all`; stay on the projects' minor line |
| `NODE_VERSION`, `NODE_SHA256` | SHA-256 | the release's `SHASUMS256.txt`; stay on the 24 line until the projects move |
| `CARGO_DENY_VERSION`, `CHEZMOI_VERSION`, `GH_VERSION`, `UV_VERSION`, `YQ_VERSION` (+ `_SHA256`) | release asset digest | `make check-updates` |
| `OPENCODE_VERSION`, `OPENCODE_INTEGRITY` (a minimum) | npm's SHA-512 integrity of `@opencode/cli-linux-x64` (no build provenance) | `make check-updates`, from the package's `latest` tag; opencode updates itself in between, so bump it only to raise the floor. opencode 2 is only on npm: the GitHub releases of `anomalyco/opencode` are opencode 1 |
| `GOLANGCI_LINT_VERSION`, `GORELEASER_VERSION` (+ `_SHA256`) | release asset digest | bump together with the projects that pin them (pre-commit revs, release workflows) |
| `OPENTOFU_VERSION`, `TFLINT_VERSION`, `TERRAFORM_DOCS_VERSION`, `TRIVY_VERSION` (+ `_SHA256`) | release asset digest | `make check-updates`; bump together with the OpenTofu projects' CI pins. The Dockerfile's `TRIVY_VERSION` is the image's tool; the workflows' scanner is always Trivy's latest release |
| `DROAST_VERSION`, `SHELLCHECK_VERSION` (+ `_SHA256`) | release asset digest | `make check-updates`; bump together with the projects' droast hook rev and their `setup-droast` and `setup-shellcheck` actions |
| `RUSTUP_VERSION`, `RUSTUP_SHA256` | SHA-256 | `make check-updates`, from rustup's `release-stable.toml` and the archived `rustup-init.sha256`; only the installer: rustup updates itself in the home volume |
| `RUST_MINIMUM` (a minimum) | rustup (the channel manifest's checksums), at start | `make check-updates`, from the stable channel; `rustup update` moves above it in between, so bump it only to raise the floor |
| `DOCKER_CLI_VERSION`, `DOCKER_BUILDX_VERSION`, `DOCKER_COMPOSE_VERSION` | Docker's apt signature, key fingerprint `DOCKER_SIGNER_FINGERPRINT` | `make check-updates` reads Docker's Ubuntu `resolute` `Packages` index |
| `DOCKER_SIGNER_SHA256` (Docker's apt key file) | SHA-256, then the key's fingerprint | only when the build fails on it: `curl -fsSL https://download.docker.com/linux/ubuntu/gpg \| sha256sum`, after checking the fingerprint is still `DOCKER_SIGNER_FINGERPRINT` |
| CI's ShellCheck (`setup-shellcheck` of gh-composite-actions, its `version:` in `ci.yaml`), for droast's ShellCheck bridge | release asset digest (the action's) | bump together with the `shellcheck-py` rev in `.pre-commit-config.yaml`; a version the action has no default digest for also needs its `sha256:` input. The droast rev itself is Dependabot's |
| `PLAYWRIGHT_VERSION` | npm | bump together with the projects' `@playwright/test` |
| `PRE_COMMIT_VERSION` | PyPI | keep in step with the projects' CI pin |
| Dockerfile frontend (`# syntax=docker/dockerfile:<version>@sha256:…`) | digest | by hand: `docker buildx imagetools inspect docker/dockerfile:<version>`, tag and digest together |
| Release tooling: `REGISTRY_IMAGE`, `SKOPEO_IMAGE` in `release.yaml` | digests | by hand, as [release.md](release.md#what-the-workflows-trust) describes; svu and Trivy come with the gh-composite-actions pin |
| Ubuntu packages | apt signatures (Ubuntu's archive key) | not pinned (droast's DF005 stays below `min-severity`): they follow the base's security updates |

## Base image

The base is pinned by index digest, in one literal `FROM ubuntu:26.04@sha256:<digest> AS base`
that both stages build on, so CI tests the base the release ships, and the release asserts it
from the build's provenance ([release.md](release.md#what-ci-proves)). A security rebuild of
`ubuntu:26.04` is a new digest, which Dependabot's `docker` entry proposes weekly as
`fix(deps)`, so merging it releases a patch. Until then, a fixable finding the base carries fails
both the release scan and the weekly scheduled scan, which is the signal to merge or make the bump
by hand. Dependabot does not read `ARG` defaults, which is
why the pin is not an `ARG BASE_IMAGE`. Its `ubuntu` version updates are ignored, so only the
digest moves. Moving to the next release is a deliberate change: the base tag and digest, the
Docker repository's codename (`resolute`) and its pinned package versions, then the full test
round.

After a base change, clear the operating-system-specific caches in the home volume: the
Playwright browsers (`~/.cache/ms-playwright`) are built per distribution and release, and a
stale build fails at launch with a missing shared library. pre-commit's environments
(`~/.cache/pre-commit`) are safest rebuilt too.

Dependabot covers the GitHub Actions, the pre-commit hooks and the base image's digest. It cannot
bump the `ARG` pins, which is what `make check-updates` is for.
