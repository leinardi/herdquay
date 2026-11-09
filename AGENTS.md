# AGENTS.md

## What this is

HerdQuay: a Docker image for a persistent, remotely accessible AI coding environment in the owner's
homelab. One container runs an unprivileged sshd, a headless Herdr server, Claude Code (with
Remote Control on its interactive sessions), opencode, Git, the GitHub CLI and the toolchains of
the owner's projects. [`README.md`](README.md) is the user-facing contract.

Scope of this repository: the image, its local Compose harness, its tests and its docs. Deploying
it to the owner's homelab (Ansible, Docker Swarm, TrueNAS datasets, pfSense rules) lives in the
separate, private `homelab` repository, with its homelab-specific requirements, and is never changed
from here; `docs/deployment.md` is the generic contract.

## Common commands

```bash
make check               # pre-commit on all files: the local gate, as CI's pre-commit-all
make check-stage         # pre-commit on the staged files only
make pre-commit-install  # installs the pre-commit and commit-msg hooks
make mk-common-update    # refresh the shared .mk snippets from leinardi/make-common@v1
make image-build         # builds herdquay:local
make image-test          # smoke + supervision tests against the built image
make image-release-smoke # the release's short smoke test against the built image
make compose-up          # the local harness on 127.0.0.1:2222 (make local-secrets first)
make check-updates       # pins with a newer upstream release
make help                # lists every target
```

Before calling a change done, run `make check`: checkmake, actionlint, markdownlint, shellcheck,
prettier, yamllint, dclint, droast (Dockerfile Roast) and the license headers. pre-commit builds
droast from source at its pinned rev, which needs a Rust toolchain (`cargo`) locally. Its required
ShellCheck bridge runs the `shellcheck` on PATH, so install ShellCheck locally at the
`shellcheck-py` rev's release (CI installs it with gh-composite-actions' `setup-shellcheck`). In CI,
`ci-result` is the one required check: it needs `pre-commit-all`, `conventional-commits`, `changes`
and `image` (`ci.yaml`); `image` checks the Dockerfile pins (`check-pinned-bases`), builds the image
and runs the smoke, supervision and release smoke tests. It may only be skipped on a pull request
where `changes` found no image input changed: a push to `main` always builds, because the release
gates on CI of its exact commit instead of re-running the suites
([`docs/release.md`](docs/release.md#what-ci-proves)). The reviewdog jobs only annotate pull
requests.

The Makefile pulls shared snippets from `leinardi/make-common@v1` into `.mk/` on first run. Project
targets live in the local `.mk/*.mk` files listed in `MK_LOCAL_FILES`, never as recipes in the
Makefile.

## Layout

| Path | What lives there |
| --- | --- |
| `Makefile`, `.mk/`, `scripts/bootstrap-mk-common.sh` | make-common: shared snippets in `MK_COMMON_FILES`, local ones in `MK_LOCAL_FILES` |
| `.github/workflows/ci.yaml` | `pre-commit-all`, `conventional-commits`, `changes`, `image` and the `ci-result` aggregator; the reviewdog jobs on pull requests |
| `.github/workflows/release.yaml`, `scheduled-scan.yaml`, `.trivyignore.yaml` | the dispatched release (`guard`, `ci-green`, `release`: image to GHCR, attested, signed; [`docs/release.md`](docs/release.md)), the weekly scan of `:latest`, and the scans' accepted findings |
| `Dockerfile` | the image: a digest-pinned Ubuntu 26.04 `base` stage, a `fetch` stage that downloads and verifies every non-apt artifact, then the final stage on the same base |
| `container/bin/` | `herdquay-entrypoint` (supervisor), `herdquay-agents` (restore check and fallback), `herdquay-healthcheck`, `herdquay-claude-install` and `herdquay-rust-install` (installs into the home volume at start), `herdquay` (doctor), `herdquay-github` (GitHub App tokens, Git credential helper), `herdquay-gpg` (commit signing), the `gh` wrapper |
| `container/etc/`, `container/share/`, `container/keys/` | sshd config, system gitconfig (credential helper, HTTPS rewrites), profile; seeded Herdr config; Anthropic's release key |
| `compose.yaml`, `compose.github.yaml` | the local test harness (SSH on loopback), and its optional GitHub App key, App ID and signing key |
| `scripts/local-secrets.sh`, `scripts/check-updates.sh` | the harness's ACL-provisioned secrets; the report of pins with newer releases |
| `tests/` | `smoke.sh` and `supervision.sh` (CI), `release-smoke.sh` (the release's short test, also in CI), `lib.sh`, `github-stub.py` and `docker-stub.py` (the smoke test's stub GitHub and Docker APIs) |
| `docs/` | operations, security, dev environment, updating, Docker access, deployment, devbox comparison; `herdr-api.schema.json` (Herdr's API at the pinned version) |
| `.github/workflows/pre-commit-warmup.yaml` | refreshes the pre-commit cache on `main` (hook config change, weekly) and prunes the older entries |
| `scripts/check-license-headers.sh` | the MIT license-header check, an always-run pre-commit hook ([License headers](#license-headers)) |
| `droast.toml`, `.dclintrc`, `.dockerignore` | Dockerfile and Compose lint rules, and the build context's exclusions |
| `.agents/skills/` | project skills; `.claude/skills` is a symlink to it |

### Generated or vendored: never hand-edit

- `.mk/help.mk`, `.mk/pre-commit.mk`, `.mk/password.mk` and `.mk/.mk-common-version`: fetched from
  `leinardi/make-common`, refreshed with `make mk-common-update`.
- `scripts/bootstrap-mk-common.sh`: also from make-common; a change is ported upstream.

## Conventions

- Pin every action and reusable workflow by full commit SHA, with the version in a trailing comment
  (`@<sha> # vX.Y.Z`).
- Give every workflow a top-level `permissions: contents: read`, and widen it only on the job that
  needs more.
- Pass `${{ }}` expressions into `run:` scripts through `env:`, never inline them in the script.
- Name workflow files `.yaml`, except a file whose name a trusted publisher (PyPI, npm) is bound to.
- A new gating CI job is added to `ci-result`'s `needs`. A hook that needs a system tool gets that
  tool installed in `pre-commit-all`; a hook that a dedicated job runs instead is listed in
  `pre-commit-all`'s `SKIP`, with the job named in a comment.
- `README.md` is the user-facing contract: keep it in step with what the repository does.
- **No secret ever enters the image or Git**: no SSH key, GitHub App key, token, signing key,
  Claude credential or `authorized_keys`, not even in a test or an example. They reach the
  container as secret files at run time; the local harness keeps its copies in the ignored
  `local/` directory.
- **No Docker socket, and never a read-write path to the host's Docker daemon** (no read-write
  proxy). The one daemon HerdQuay may reach is a dedicated rootless one, an opt-in of the
  deployment that `herdquay doctor` checks (`docs/docker-diagnostics.md`). Optional read-only
  diagnostics are a separate, opt-in deployment decision.
- Every tool the image downloads is pinned and verified by checksum in the Dockerfile, and the base
  image is pinned by digest in one literal `FROM ubuntu:26.04@sha256:… AS base`, which Dependabot
  moves (`docs/updating.md`). `check-pinned-bases` enforces both in CI and the release.

## GitHub conventions

Shared by every `leinardi/*` repository.

- **Jobs:** every job sets `timeout-minutes` (a composite action cannot time out its own steps).
  Every checkout that pushes nothing sets `persist-credentials: false`; the release's checkout
  sets it too, and its tag push passes the token to that one `git push`.
- **Concurrency:** CI groups a pull request's runs by `${{ github.workflow }} @ <head label>` and
  cancels the older one; every other run (a push to the default branch, a dispatch) gets its own
  group, `${{ github.run_id }}`, because GitHub keeps one pending run per group and the release
  gate needs CI on the exact commit (see `ci.yaml`). A warm-up uses `<name>-${{ github.ref }}`,
  never a static group. The release uses the one `release` group and is never cancelled.
- **Caches:** the default branch is the only writer, because every pull request can restore its
  caches and the default branch cannot restore a pull request's. The pre-commit cache is saved
  only by `pre-commit-warmup.yaml`; CI restores it with `actions/cache/restore` under the same key,
  `pre-commit|<OS>|<resolved Python version>|<hash of .pre-commit-config.yaml>`, so CI sets up the
  warm-up's `python_version` and installs its pre-commit version. CI's buildx cache is
  `scope=ci-herdquay`, written on `main` only; the release writes `scope=release-herdquay`.
- **pre-commit** is pinned to the same version in CI, the warm-up and the
  `gha-pre-commit-reviewdog-actions` jobs (their `pre-commit-version` input).
- **Release:** `release.yaml` is a `workflow_dispatch` with an optional `version` and a `dry_run`,
  built from gh-composite-actions (`release-version`, `require-ci-green`, `release-mode`,
  `check-pinned-bases`, `trivy-gate`). svu derives the version from the commits only when none is
  given, and is installed only then, so a version entered by hand releases even when GitHub's
  release downloads fail. Trivy is never pinned: `trivy-gate` installs its latest release. A push
  to `main` that merges a Dependabot pull request releases a patch on its own when only
  Dependabot's work is unreleased and one commit is a `fix(deps)` (gh-reusable-workflows'
  `dependabot-release` with `ecosystems: docker`); every other push stops at that job.
- **Dependabot:** monthly, `cooldown: default-days: 7`, labels `dependencies` and `ci`, one group
  per ecosystem. The `docker` entry (the base digest) ships, so it is weekly and uses
  `fix(deps)`; GitHub Actions and pre-commit use `chore(deps)`.
- **Issue and pull request templates:** keep the Step 1/2/3 structure of template-default, with
  this repository's project name, version command, environment block, snippet language and extra
  checkboxes. The pull request checklist always keeps the Conventional Commits and
  validation-matrix items.

## License headers

Every code file carries the MIT header, with the year the file was first committed:
`git log --diff-filter=A --follow --format=%ad --date=format:%Y -- <file> | tail -1`. Governed:
shell scripts, Dockerfiles, the Makefile and the repo-local `.mk` fragments; never YAML, JSON or
Markdown. `scripts/check-license-headers.sh`, an always-run pre-commit hook, fails on a governed
file without it. The make-common files and `scripts/bootstrap-mk-common.sh` carry make-common's own
header and are exempt. Copy the header from any governed file; the IntelliJ copyright profile in
`.idea/copyright/` (MIT) adds it to new files. A file adapted from rozsival/devbox (MIT) also keeps
devbox's copyright line.

## Markdown

Prose wraps at 100 columns (markdownlint `line-length`, `.editorconfig`); tables, code blocks and
headings may run longer. Never wrap inside a table, a code block or a link target.

## Commit messages

All commits MUST be Conventional Commits 1.0.0 **with a scope**:
`<type>(<scope>)[!]: <description>`, optional blank-line body and footers. Enforced by the
`conventional-pre-commit` `commit-msg` hook (`--force-scope`, installed by
`make pre-commit-install`) and by the `conventional-commits` CI job. Types: `feat`, `fix`, `docs`,
`test`, `refactor`, `perf`, `build`, `ci`, `chore`, `style`, `revert`. Breaking changes use `!`
before `:` or a `BREAKING CHANGE:` footer. Release notes are not built from these messages:
`gh release create --generate-notes` lists the merged pull requests by title. Examples:
`fix(ci): pin actionlint by SHA`, `feat(release): attach the build to the release`.

A release with no explicit version is derived by `svu` from the commits since the last `vX.Y.Z` tag,
so a wrong type ships a wrong version:

| Release | Commit | Example |
| --- | --- | --- |
| major | any type with `!` before the colon, or a `BREAKING CHANGE:` footer | `feat(api)!: drop the v1 endpoints` |
| minor | `feat` | `feat(release): attach the build to the release` |
| patch | `fix` | `fix(ci): pin actionlint by SHA` |
| none | everything else: `perf`, `refactor`, `build`, `ci`, `chore`, `docs`, `style`, `test`, `revert` | `docs(readme): fix a link` |

The highest bump among the commits wins; with only "none" commits since the last tag, a release
with no version fails with "nothing to bump".

**Pick the type by whether the change should ship, not by what kind of change it is.** Anything
that changes what the project ships and that users should receive is `fix` (or `feat`), even when
it is a performance improvement, a refactor or a revert. Use `perf`, `refactor`, `style` and
`revert` only when the commit is deliberately not meant to trigger a release on its own. A `revert`
of a shipped `feat` or `fix` is itself a `fix`. `svu` matches `feat`/`fix` anywhere in the subject
(e.g. `prefix:` counts as `fix:`), so avoid a word ending in `feat` or `fix` directly before a colon
in other subjects. PRs land as merge commits, so every commit counts, not just the PR title.

Releases are cut by dispatching `release.yaml` on `main` ([`docs/release.md`](docs/release.md)),
or on their own by a Dependabot `fix(deps)` merge (base digest).
The first one needs an explicit version: there is no tag to derive it from. Tags are immutable, so
a wrong release is answered with a higher version, never a moved tag.

## Validation matrix

Run before considering an edit done. `make check` applies to every row.

| You edited | Run |
| --- | --- |
| `.github/workflows/**`, `.github/dependabot.yml` | `pre-commit run actionlint --all-files`; reason through each trigger the workflow has (pull request, push, dispatch, schedule); for `release.yaml`, keep `docs/release.md` in step and dispatch a dry run once CI passed on the commit; for `ci.yaml`'s `image` job and `changes` filter, keep `docs/release.md#what-ci-proves` true |
| `.trivyignore.yaml` | every entry scoped to paths, with a statement and an `expired_at`; scan `herdquay:local` with the release's Trivy command |
| `.pre-commit-config.yaml` | `make check`; a hook that needs a system tool also gets it in `ci.yaml`'s `pre-commit-all` |
| `Makefile`, the `.mk/*.mk` files in `MK_LOCAL_FILES` | `make check` (checkmake), `make help` |
| `scripts/bootstrap-mk-common.sh`, the make-common `.mk` files | never by hand: port the change to make-common, then `make mk-common-update` and `make help` |
| `scripts/check-license-headers.sh` | `make check` (shellcheck and the hook itself); strip one governed file's header and confirm the check names it |
| `Dockerfile`, `droast.toml`, `container/**` | `make check` (droast, shellcheck, license headers); gh-composite-actions' `check-pinned-bases/check-pinned-bases.sh Dockerfile`; `make image-build image-test image-release-smoke`; keep `docs/updating.md` and `docs/dev-environment.md` in step |
| `tests/**`, `scripts/local-secrets.sh` | `make image-test image-release-smoke` |
| `compose*.yaml`, `.dclintrc` | `make check` (dclint) |
| `**/*.md`, `.agents/skills/**` | `make check` (markdownlint); prose wrapped at 100 columns |

## Project skills

Skills live in `.agents/skills/` (symlinked as `.claude/skills`). Load `adversarial-review` for any
review request ("review my diff", "is this ready to merge").
