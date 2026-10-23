# Updating the image

Every tool is pinned in the `Dockerfile` as an `ARG`, with what verifies it. Claude Code is the one
pin the image does not contain: `herdquay-claude-install` downloads and verifies it at the first
start of an image that pins a new version. Nothing updates itself at run time: Claude Code's and
opencode's auto-updaters are off (`DISABLE_AUTOUPDATER=1`, `OPENCODE_DISABLE_AUTOUPDATE=1`) and
Herdr is never installed into the home directory, so a running container only changes with a new
image.

## Routine

```bash
make check-updates                          # lists every pin with a newer upstream release
# edit the ARG (and its digest) in the Dockerfile
make image-build image-test                 # smoke and supervision tests
make compose-up projects-test               # the five projects' workflows, in the new image
make check                                  # droast and the rest
```

Commit the bump on its own (`fix(image): …` when it should ship). CI rebuilds the image and runs
the same automated tests.

## Pins

| Pin | Verified by | Where the new value comes from |
| --- | --- | --- |
| `BASE_IMAGE` (`ubuntu:26.04`) | Docker Official Image | tag only: each build takes the latest rebuild of the LTS release |
| `HERDR_VERSION`, `HERDR_SHA256` | release asset digest (Herdr publishes no checksum file or signature) | `make check-updates` prints the digest |
| `CLAUDE_VERSION` | GPG signature of the release manifest, then the binary's checksum in it, both at first start | the stable channel, `https://downloads.claude.ai/claude-code-releases/stable` |
| `CLAUDE_SIGNER_FINGERPRINT`, `container/keys/claude-code.asc` | pinned fingerprint | only when Anthropic rotates its release key: compare the new fingerprint with the [setup docs](https://code.claude.com/docs/en/setup) before replacing both |
| `GO_VERSION`, `GO_SHA256` | SHA-256 | `https://go.dev/dl/?mode=json&include=all`; stay on the projects' minor line |
| `NODE_VERSION`, `NODE_SHA256` | SHA-256 | the release's `SHASUMS256.txt`; stay on the 24 line until the projects move |
| `GH_VERSION`, `YQ_VERSION` (+ `_SHA256`) | release asset digest | `make check-updates` |
| `OPENCODE_VERSION`, `OPENCODE_INTEGRITY` | npm's SHA-512 integrity of `@opencode/cli-linux-x64` (no build provenance) | `make check-updates`, from the package's `latest` tag. opencode 2 is only on npm: the GitHub releases of `anomalyco/opencode` are opencode 1 |
| `GOLANGCI_LINT_VERSION`, `GORELEASER_VERSION`, `HADOLINT_VERSION` (+ `_SHA256`) | release asset digest | bump together with the projects that pin them (pre-commit revs, monmux's release workflow); hadolint is only for the projects' hooks, this repository lints with droast |
| `DOCKER_CLI_VERSION`, `DOCKER_BUILDX_VERSION`, `DOCKER_COMPOSE_VERSION` | Docker's apt signature, key fingerprint `DOCKER_SIGNER_FINGERPRINT` | `make check-updates` reads Docker's Ubuntu `resolute` `Packages` index |
| `.github/actions/setup-shellcheck` (CI only, for droast's ShellCheck bridge) | release asset digest | bump together with the `shellcheck-py` rev in `.pre-commit-config.yaml`; the droast rev itself is Dependabot's |
| `PLAYWRIGHT_VERSION` | npm | bump together with `@playwright/test` in bitgauge and runhold |
| `PRE_COMMIT_VERSION` | PyPI | keep in step with the projects' CI pin |
| Ubuntu packages | apt signatures (Ubuntu's archive key) | not pinned (droast's DF005 stays below `min-severity`): they follow the base's security updates |
| `container/etc/ssh/ssh_known_hosts` | fingerprints in GitHub's docs | only when GitHub rotates a host key: regenerate from `https://api.github.com/meta` and compare with GitHub's published fingerprints |

## Base image

A tag pin means two builds a day apart can differ in their Ubuntu packages. That is the intended
trade: security fixes without a digest bump for every rebuild of `ubuntu:26.04`. Moving to the
next LTS is a deliberate change: the base tag, the Docker repository's codename (`resolute`) and
its pinned package versions, then the full test round.

After a base change, clear the operating-system-specific caches in the home volume: the
Playwright browsers (`~/.cache/ms-playwright`) are built per distribution and release, and a
stale build fails at launch with a missing shared library. pre-commit's environments
(`~/.cache/pre-commit`) are safest rebuilt too.

Dependabot covers the GitHub Actions and the pre-commit hooks. It cannot bump an unversioned tag
or the `ARG` pins, which is what `make check-updates` is for.
