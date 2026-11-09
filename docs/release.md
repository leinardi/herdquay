# Release

How a HerdQuay release is versioned, built and published, what to do when one fails halfway, and
what has to be set up by hand for all of it to hold. The pipeline is
[`.github/workflows/release.yaml`](../.github/workflows/release.yaml), built from the shared
actions of [gh-composite-actions](https://github.com/leinardi/gh-composite-actions)
(`release-version`, `require-ci-green`, `release-mode`, `check-pinned-bases`, `trivy-gate`); this
page is why it is shaped that way.

## What a release produces

- A `linux/amd64` image at `ghcr.io/leinardi/herdquay:<version>`, with an SBOM and `mode=max`
  BuildKit provenance in its index, a
  [build provenance attestation](https://docs.github.com/actions/security-guides/using-artifact-attestations)
  and a keyless [cosign](https://docs.sigstore.dev/) signature made with the release workflow's own
  OIDC identity. Before the version was tagged, CI had passed on the commit (the full smoke and
  supervision suites, [What CI proves](#what-ci-proves)), and that exact image passed the release's
  short smoke test and a [Trivy](https://trivy.dev/) scan with no fixable `HIGH` or `CRITICAL`
  vulnerability outside [`.trivyignore.yaml`](../.trivyignore.yaml).
- The moving image tags `:<major>` and `:latest`, and the GitHub "Latest" release marker, when the
  version is the highest released one.
- A GitHub release whose notes name the base image digest it was built on, followed by notes
  generated from the merged pull requests (and, while commits land on `main` directly, the
  commits). It carries no assets: the image is the artifact.

The image never contains Claude Code: it is downloaded and verified at the first start
([operations.md](operations.md#claude-code-at-first-start)).

Verify a published image:

```bash
gh attestation verify oci://ghcr.io/leinardi/herdquay:<version> --repo leinardi/herdquay \
  --signer-workflow leinardi/herdquay/.github/workflows/release.yaml
cosign verify ghcr.io/leinardi/herdquay:<version> \
  --certificate-identity https://github.com/leinardi/herdquay/.github/workflows/release.yaml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## How to release

Run the **Release herdquay** workflow from the Actions tab (or `gh workflow run release.yaml`) on
`main`. It takes two inputs:

- `version`: optional, `X.Y.Z` or `vX.Y.Z`. Left empty, the version is derived from the commits
  since the last release (see [Versioning](#versioning)). The **first release needs it**: with no
  tag yet there is nothing to derive from. Give it explicitly to force a version, or to recover a
  failed run with a fresh dispatch (see [Recovering a failed publish](#recovering-a-failed-publish)).
- `dry_run`: boolean, default `false`. See [Dry runs](#dry-runs).

Dispatch it once CI has run on the commit's push to `main`: the `ci-green` job waits for that run
for up to 30 minutes, and fails if it did not pass ([What CI proves](#what-ci-proves)).

**One release runs at a time.** The workflow takes a `release` concurrency group with
`cancel-in-progress: false`, so a second dispatch queues behind the first rather than racing it.

### Dependabot releases

A merge of a Dependabot pull request releases the next patch on its own, with no dispatch, when
everything since the last release is Dependabot's and at least one of its commits is a `fix(deps)`
(the base image's new digest). The workflow also runs on every push to `main`: its `dependabot`
job calls gh-reusable-workflows'
[`dependabot-release`](https://github.com/leinardi/gh-reusable-workflows/blob/main/.github/workflows/dependabot-release.md)
with `ecosystems: docker`, which checks from the API alone that every unreleased commit is
Dependabot's own (committed by GitHub) or the merge of its pull request, that the change only moves
action pins and the Dockerfile's `FROM` tag or digest, and that CI passed on the push. Then the
release runs as a dispatch would, with that patch as an explicit version. Anything else is a green
no-op with a notice: a `chore(deps)` merge (actions, pre-commit) ships nothing, and a human commit
waiting to be released leaves the release to a dispatch.

A push that merges a Dependabot pull request takes the same `release` group as a dispatch, so the
two never publish at once and a lower version never moves `latest` after a higher one. Every other
push runs in a group of its own and only skips the `dependabot` job. GitHub keeps one pending run
per group: a Dependabot merge that arrives while a release runs and a dispatch waits replaces that
dispatch, which shows as cancelled; dispatch it again.

## Versioning

Semantic versioning, derived from
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) by
[`svu`](https://github.com/caarlos0/svu), as [AGENTS.md](../AGENTS.md#commit-messages) describes:
`feat` is a minor, `fix` a patch, `!` or a `BREAKING CHANGE:` footer a major, and every other type
bumps nothing. While the version is `0.x`, `svu` turns a breaking change into a minor bump. When no
commit since the last release is a `feat`, a `fix` or a breaking change, a run with no version
**fails** with *"No feat/fix or breaking-change commit since `<tag>`, so there is nothing to bump."*
A bump of a pin that carries a security fix is committed as `fix(image)`, or released with an
explicit version; Dependabot's base digest bumps are `fix(deps)`, so they release a patch.

Whether derived or typed, the version must be **higher than every version already released**: tags
here are immutable. The only version a run may reuse is the one it is recovering, which is exactly
this version already sitting on `HEAD`.

The version is resolved by the `release-version` action. svu is installed (`setup-svu`) only when no
version is given, so a version typed by hand releases even while GitHub's release downloads fail.
Only strict `vMAJOR.MINOR.PATCH` tags are releases (`RELEASE_TAG_REGEX` in the workflow,
`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`, the actions' default too). Every lookup
filters the full tag list through that regex, never through a glob, so pointer tags (`latest`,
`v1`), pre-releases and malformed tags can never become the current version. `svu` is given the
exact tag to count from, literally. Before reasoning about versions locally, drop local tags that
are not on `origin`: `git fetch --prune --prune-tags origin`.

## Why the build happens before the tag

Tags in this repository are immutable: the "Immutable tags" ruleset, managed in
[gh-leinardi-iac](https://github.com/leinardi/gh-leinardi-iac), blocks update, deletion and
non-fast-forward of every tag except the moving `v<major>` and `latest`, with no bypass actors. A
failed release cannot delete its tag, so everything that can fail happens before the tag exists, and
everything after it can be finished by a re-run on the tagged commit.

The run has three jobs, each waiting on the one before:

1. **`guard`**: refuse anything but `main`, failing rather than skipping when `github.ref` is not
   `refs/heads/main`; then resolve the version, as in [Versioning](#versioning).
2. **`ci-green`**: `require-ci-green` on the commit. CI's run for the push of this exact commit to
   `main` (`.github/workflows/ci.yaml`, by file path, not by a check name any workflow could reuse)
   must have concluded `success`, with its `ci-result` job. This replaces the release-time lint
   and the full image tests ([What CI proves](#what-ci-proves)).
3. **`release`**, which checks the Dockerfile pins (`check-pinned-bases`, as CI does) and then
   **decides the mode** (`release-mode`) from the Git tag on the remote, the image
   `ghcr.io/leinardi/herdquay:<version>` and the GitHub release. Only "not found" counts as
   absent: any other lookup error stops the run.

   | Git tag | Published | Mode |
   | --- | --- | --- |
   | absent | nothing | **Fresh** |
   | absent | the image `:<version>`, or a GitHub release | **Stop before tagging.** The version is held |
   | on another commit |  | **Stop.** Tags are immutable: release a higher version |
   | on this commit | the image, attested and cosign-signed by this workflow for this commit | **Recovery, reuse** |
   | on this commit | the image, not attested or not signed | **Stop: needs a human** |
   | on this commit | no image | **Recovery, publish** |

   A tag on this commit must be annotated and in the clone, as this workflow makes it. The tag is
   then created **locally only**, if it does not exist yet.

A **fresh** release then runs:

1. Start a registry inside the job (`registry:3.1.2`, pinned by digest).
2. **Build the image once**, the Dockerfile's default target, with the SBOM and `mode=max`
   provenance, pushed by digest to that local registry, every layer recompressed as gzip so that
   the digest-preserving copy in step 8 works. The layer cache is the release's own
   (`scope=release-herdquay`), never CI's.
3. **Check the build used the pinned images**: the images listed in the index's provenance must
   be exactly the Dockerfile's digest pins (the base and the `# syntax=` frontend), apart from
   BuildKit's SBOM scanner, which generates the SBOM and is not part of the image.
4. **Smoke-test and scan that image**: it is pulled back from the local registry by its platform
   digest, and `tests/release-smoke.sh` checks its version and revision labels, that it turns
   healthy, that an SSH login runs its tools, and that a stop is clean. Then `trivy-gate` scans it
   (see [The scan gate](#the-scan-gate)).
5. **Gate the tag.** The highest released version is read again from the remote; a fresh release
   that is no longer the highest fails with nothing pushed.
6. **Check the version image is absent**, right before the tag.
7. **`git push origin <version>`**: the point of no return. The checkout keeps no credentials; the
   token reaches this one command as an HTTP header.
8. **Copy to GHCR, untagged**: `skopeo copy --all --preserve-digests` to
   `ghcr.io/leinardi/herdquay@<digest>`, with skopeo pinned by digest.
9. **Check, attest, sign.** The index GHCR serves under the digest must hash to the tested digest;
   then it is attested and signed.
10. **Tag the image** `:<version>`, after checking once more that the tag is absent.

The GitHub release and the latest pointers follow, in every mode. Everything stamped into the image
comes from the commit: the version, the full commit SHA, the commit date as `created`, and the
commit time as `SOURCE_DATE_EPOCH`. The image is not byte-reproducible (apt packages follow
Ubuntu's archive, and the provenance records the build), which is why a recovery never compares a
rebuilt index with a published one.

## What CI proves

The release runs a short smoke test, not the full smoke and supervision suites (`tests/smoke.sh`,
about 3.5 minutes, and `tests/supervision.sh`). That is sound only because CI already ran them on
the same inputs, and the `ci-green` job pins that to the commit being released:

- **The same commit.** `require-ci-green` accepts only the `push` run of `ci.yaml` whose head is
  the release's own SHA, on `main`, and its `ci-result` job must have passed on the run's newest
  attempt.
- **The image was built and tested on that commit.** `ci-result` needs the `image` job, which
  builds the image and runs both suites and the release's smoke test. Its `changes` filter only
  skips the build on a pull request that touches no image input. A push to `main` and a dispatch
  always build, because a skip there would only say "nothing changed since the previous push",
  whose own CI may have failed, and would prove nothing about this commit.
- **The same build.** CI and the release build the same Dockerfile, its default target, from the
  same context (`.dockerignore` keeps `.git`, docs and tests out). The build arguments differ only
  in what the labels say (`VERSION`, `REVISION`, `CREATED`) and `SOURCE_DATE_EPOCH`; the release
  adds the SBOM, the provenance and gzip layers, which do not change what runs.
- **The same base.** The base is pinned by digest, and `check-pinned-bases` fails CI and the
  release on any `FROM` without one, or any download in the Dockerfile not followed by a checksum
  check; the release then asserts from the provenance that the build pulled exactly the pins.

What can still differ is what the build fetches at build time and no pin covers: Ubuntu's apt
packages (unpinned on purpose, DF005 in `droast.toml`, signed by Ubuntu's archive key). The
smoke test and the scan run on the release's own build, so a broken or vulnerable package that
arrived since CI still stops the release before the tag.

## The scan gate

This is a 2.6 GB workstation image on Ubuntu, so unlike a minimal image it always carries
vulnerabilities with no fix yet, nearly all in Ubuntu's packages. Nothing in this repository can fix
those, so the gate (`trivy-gate`) leaves them out (`--ignore-unfixed`): only a `HIGH` or
`CRITICAL` finding **with a fix upstream** can fail a release. Trivy is always its latest release,
never pinned, so every scan runs the newest checks.

The base's findings count the same as the image's own: a fixable finding in `ubuntu:26.04` fails
the release too. Its fix is usually the base's next digest, which Dependabot proposes weekly; until
it ships, a reviewed entry in the ignore file below is the only way past the gate.

Many fixable findings are in a dependency of a pinned tool (the Go standard library a release was
built with, npm's bundled modules) rather than in anything a bump here can change. Those go in
[`.trivyignore.yaml`](../.trivyignore.yaml), each entry scoped to the paths it was found in, with a
statement saying why and an expiry date Trivy enforces. When an entry expires, bump the tool if a
fixed release is out, otherwise extend the date with a fresh reason. A finding in a tool that is
held back on purpose ([updating.md](updating.md)) is accepted the same way, and bumped together
with the projects that hold it.

## Dry runs

`dry_run: true` rehearses a fresh release: it resolves the version and decides the mode, then runs
the CI gate and fresh steps 1 to 6 (the smoke test and the scan included), and exercises step 8 by
copying the index to a **second job-local registry** instead of GHCR, checking that the copy keeps
its digest and its attestation manifest. It pushes no tag and publishes nothing. A dry run with no
version is also the quickest way to see what version the commits would produce.

## Recovering a failed publish

A recovery runs on the tagged commit, because that is the only commit the tag check accepts for an
existing tag:

- **"Re-run failed jobs" (or "Re-run all jobs") on the failed run.** This always works: a re-run
  keeps the original run's commit and inputs, whatever has been merged since.
- **A fresh dispatch with the same version, given explicitly**, while `main` still points at the
  tagged commit.

The mode decision then picks one of two recoveries:

- **Recovery, reuse**, when `:<version>` exists and is attested and signed by this workflow for this
  commit: `release-mode` verifies both, and the image is reused by digest. Nothing is built again.
  It is scanned, and findings are reported as warnings: it is already published and immutable.
- **Recovery, publish**, when the tag exists and `:<version>` does not: a new build, checked against
  the pins, smoke-tested, scanned, copied, checked, attested, signed and tagged. If the scan now
  fails, because a fixable vulnerability the image adds was published since, **the version is
  abandoned**: its tag stays, with no image, and the fix goes out as a higher version.

There is no cleanup step and the tag is never deleted. A wrong release (the wrong commit, a bad
build) is answered with a new version, not a moved tag. The stop rows of the table are for a human:
find out where the image or release came from, and release a higher version. A recovery re-run also
needs CI green on the tagged commit, as every run does: "Re-run failed jobs" keeps the original
commit, whose CI already passed.

## Recovery guarantees

**A published artifact is never replaced, and it is reused only once it is proven to be this
run's.** A new image is copied to GHCR by digest with no tag, attested and signed, and only then
tagged `:<version>`, so a version tag only ever points at a digest this workflow tested, scanned,
attested and signed; an untagged digest left by a failed run is inert. A reused image must pass
`gh attestation verify … --source-ref refs/heads/main --source-digest <commit>` and carry this
workflow's own cosign signature (identity
`https://github.com/leinardi/herdquay/.github/workflows/release.yaml@refs/heads/main`, issuer
`https://token.actions.githubusercontent.com`), both checked by `release-mode` before anything
else. The GitHub release is created as a draft if it does not exist, and one carrying any asset
stops the run, both in `release-mode` and right before publishing, since this workflow never
uploads one.

`:latest`, `:<major>` and the GitHub "Latest" marker move only if the version is still the highest
when each is moved, read again from the remote right before. That is **best-effort, not atomic**: if
a tag created outside this workflow lands between the two moves, the run warns rather than moving
anything back. Re-dispatch the higher version, or retag by hand after checking the digest:

```bash
IMAGE=ghcr.io/leinardi/herdquay
DIGEST=sha256:...   # the digest of the image that should be latest
gh attestation verify "oci://$IMAGE@$DIGEST" --repo leinardi/herdquay \
  --signer-workflow leinardi/herdquay/.github/workflows/release.yaml --source-ref refs/heads/main
docker buildx imagetools create -t "$IMAGE:latest" -t "$IMAGE:<major>" "$IMAGE@$DIGEST"
```

## Scheduled scan

[`.github/workflows/scheduled-scan.yaml`](../.github/workflows/scheduled-scan.yaml) runs every
Monday, and on demand. It resolves `:latest` to its index digest once and scans the `linux/amd64`
image by its own digest with the release's gate (`trivy-gate`, the latest Trivy, the same ignore
file): every fixable finding fails the run, the base's included. The
published image is immutable, so the fix is a new release (for a base finding, on the base's newer
digest), or a reviewed entry in the ignore file.

## What the workflows trust

**Every action is pinned to a full commit SHA**, with the version in a trailing comment; Dependabot
updates them. The one tool deliberately not pinned is Trivy, which `trivy-gate` installs at its
latest release so every scan runs the newest checks. svu is pinned, with its checksum, inside
`setup-svu`. **Every image the release job runs or builds on is pinned by digest**: the job-local
registry and skopeo in the workflow's `env`, the Dockerfile frontend (`# syntax=…@sha256:…`) and
the base. Dependabot moves the base's digest ([updating.md](updating.md#base-image)); bump the
others by hand, resolving a new digest with `docker buildx imagetools inspect <image>:<tag>`.

**Workflow tokens are read-only by default.** Each workflow sets `permissions: contents: read` at
the top; only the release job adds `contents: write`, `packages: write`, `id-token: write` and
`attestations: write`, and `ci-green` adds `actions: read`. The release's BuildKit layer cache is
its own scope (`release-herdquay`), which only this workflow reads and writes; CI's
(`ci-herdquay`) is written only on `main`, so no pull request can seed a layer the release
builds from.

## One-time setup

1. **Make the repository public**, in gh-leinardi-iac (`visibility` in
   `stacks/github-repos/repos.tf`). The "Immutable tags" ruleset is only applied to public
   repositories, artifact attestations need a public repository on this plan, and a private one
   would put its name and commits into Sigstore's public transparency log when the image is signed.
2. **Create the `release` environment** (Settings → Environments) **before the first dispatch**,
   dry runs included: a run that references a missing environment creates it with no protection
   rules. Restrict it to `main` with a deployment branch rule, and add required reviewers if a
   release should wait for a human. It needs no secret: GHCR is reached with the job's own token.
3. **Check the package is public** after the first release, and make it so if not: Packages →
   `herdquay` → Package settings → Change visibility. The homelab pulls it without a registry
   login.
