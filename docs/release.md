# Release

How a HerdQuay release is versioned, built and published, what to do when one fails halfway, and
what has to be set up by hand for all of it to hold. The pipeline is
[`.github/workflows/release.yaml`](../.github/workflows/release.yaml), adapted from
leinardi/awtrix-controller's; this page is why it is shaped that way.

## What a release produces

- A `linux/amd64` image at `ghcr.io/leinardi/herdquay:<version>`, with an SBOM and `mode=max`
  BuildKit provenance in its index, a
  [build provenance attestation](https://docs.github.com/actions/security-guides/using-artifact-attestations)
  and a keyless [cosign](https://docs.sigstore.dev/) signature made with the release workflow's own
  OIDC identity. Before the version was tagged, that exact image passed the smoke and supervision
  tests and a [Trivy](https://trivy.dev/) scan with no fixable `HIGH` or `CRITICAL` vulnerability
  outside [`.trivyignore.yaml`](../.trivyignore.yaml).
- The moving image tags `:<major>` and `:latest`, and the GitHub "Latest" release marker, when the
  version is the highest released one.
- A GitHub release with notes generated from the merged pull requests (and, while commits land on
  `main` directly, the commits). It carries no assets: the image is the artifact.

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

**One release runs at a time.** The workflow takes a `release` concurrency group with
`cancel-in-progress: false`, so a second dispatch queues behind the first rather than racing it.

## Versioning

Semantic versioning, derived from
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) by
[`svu`](https://github.com/caarlos0/svu), as [AGENTS.md](../AGENTS.md#commit-messages) describes:
`feat` is a minor, `fix` a patch, `!` or a `BREAKING CHANGE:` footer a major, and every other type
bumps nothing. While the version is `0.x`, `svu` turns a breaking change into a minor bump. When no
commit since the last release is a `feat`, a `fix` or a breaking change, a run with no version
**fails** with *"No feat/fix or breaking-change commit since `<tag>`, so there is nothing to bump."*
A bump of the base image or a pin that carries a security fix is committed as `fix(image)`, or
released with an explicit version.

Whether derived or typed, the version must be **higher than every version already released**: tags
here are immutable. The only version a run may reuse is the one it is recovering, which is exactly
this version already sitting on `HEAD`.

Only strict `vMAJOR.MINOR.PATCH` tags are releases (`RELEASE_TAG_REGEX` in the workflow,
`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`). Every lookup filters the full tag list
through that regex, never through a glob, so pointer tags (`latest`, `v1`), pre-releases and
malformed tags can never become the current version. `svu` is given the exact tag to count from,
literally, as `--tag.pattern`. Before reasoning about versions locally, drop local tags that are not
on `origin`: `git fetch --prune --prune-tags origin`.

## Why the build happens before the tag

Tags in this repository are immutable: the "Immutable tags" ruleset, managed in
[gh-leinardi-iac](https://github.com/leinardi/gh-leinardi-iac), blocks update, deletion and
non-fast-forward of every tag except the moving `v<major>` and `latest`, with no bypass actors. A
failed release cannot delete its tag, so everything that can fail happens before the tag exists, and
everything after it can be finished by a re-run on the tagged commit.

1. **Refuse anything but `main`.** The `guard` job fails, rather than skips, when `github.ref` is
   not `refs/heads/main`, and every other job waits on it.
2. **Verify.** `lint` runs every pre-commit hook, a copy of CI's `pre-commit-all`, so a release
   never depends on which push last ran CI. The image tests run later, on the built image itself.
3. **Resolve the version**, as in [Versioning](#versioning).
4. **Check the tag.** If `refs/tags/<version>` exists on the remote, the run continues only when it
   points at `HEAD`, as a recovery. The tag is then created **locally only**.
5. **Decide the mode**, from the Git tag on the remote and the image
   `ghcr.io/leinardi/herdquay:<version>`. Only "not found" counts as absent: an authentication or
   network error stops the run.

   | Git tag | Image `:<version>` | Mode |
   | --- | --- | --- |
   | absent | absent | **Fresh** |
   | absent | present | **Stop before tagging.** The version is held by an image |
   | on this commit | present, attested by this workflow for this commit | **Recovery, reuse** |
   | on this commit | present, not attested | **Stop: needs a human** |
   | on this commit | absent | **Recovery, publish** |

A **fresh** release then runs:

1. Start a registry inside the job (`registry:3.1.2`, pinned by digest).
2. **Build the image once**, with the SBOM and `mode=max` provenance, pushed by digest to that local
   registry, every layer recompressed as gzip so that the digest-preserving copy in step 7 works.
3. **Test and scan that image**: it is pulled back from the local registry by its platform digest
   and the smoke and supervision tests run against it, then Trivy scans it (see
   [The scan gate](#the-scan-gate)):

   ```bash
   trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
     --ignorefile .trivyignore.yaml --exit-code 1 --platform linux/amd64 <image>@<digest>
   ```

4. **Gate the tag.** The highest released version is read again from the remote; a fresh release
   that is no longer the highest fails with nothing pushed.
5. **Check the version image is absent**, right before the tag.
6. **`git push origin <version>`**: the point of no return.
7. **Copy to GHCR, untagged**: `skopeo copy --all --preserve-digests` to
   `ghcr.io/leinardi/herdquay@<digest>`, with skopeo pinned by digest.
8. **Check, attest, sign.** The index GHCR serves under the digest must hash to the tested digest;
   then it is attested and signed.
9. **Tag the image** `:<version>`, after checking once more that the tag is absent.

The GitHub release and the latest pointers follow, in every mode. Everything stamped into the image
comes from the commit: the version, the full commit SHA, the commit date as `created`, and the
commit time as `SOURCE_DATE_EPOCH`. The image is not byte-reproducible (the base is pinned by tag,
apt packages follow it, and the provenance records the build), which is why a recovery never
compares a rebuilt index with a published one.

## The scan gate

This is a 2.6 GB workstation image on Ubuntu, so unlike a minimal image it always carries
vulnerabilities with no fix yet, nearly all in Ubuntu's packages. Nothing in this repository can fix
those, and the base's security rebuilds bring the fixes, so the gate uses `--ignore-unfixed`: only a
`HIGH` or `CRITICAL` finding **with a fix upstream** fails a release.

Many fixable findings are in a dependency of a pinned tool (the Go standard library a release was
built with, npm's bundled modules) rather than in anything a bump here can change. Those go in
[`.trivyignore.yaml`](../.trivyignore.yaml), each entry scoped to the paths it was found in, with a
statement saying why and an expiry date Trivy enforces. When an entry expires, bump the tool if a
fixed release is out, otherwise extend the date with a fresh reason. A finding in a tool that is
held back on purpose ([updating.md](updating.md)) is accepted the same way, and bumped together
with the projects that hold it.

## Dry runs

`dry_run: true` rehearses a fresh release: it resolves the version and decides the mode, then runs
fresh steps 1 to 5 (the tests and the scan included) and exercises step 7 by copying the index to a
**second job-local registry** instead of GHCR, checking that the copy keeps its digest and its
attestation manifest. It pushes no tag and publishes nothing. A dry run with no version is also the
quickest way to see what version the commits would produce.

## Recovering a failed publish

A recovery runs on the tagged commit, because that is the only commit the tag check accepts for an
existing tag:

- **"Re-run failed jobs" (or "Re-run all jobs") on the failed run.** This always works: a re-run
  keeps the original run's commit and inputs, whatever has been merged since.
- **A fresh dispatch with the same version, given explicitly**, while `main` still points at the
  tagged commit.

The mode decision then picks one of two recoveries:

- **Recovery, reuse**, when `:<version>` exists and is attested by this workflow for this commit:
  the published image is verified by its attestation and its signature and reused by digest.
  Nothing is built again. It is scanned, and findings are reported as warnings: it is already
  published and immutable.
- **Recovery, publish**, when the tag exists and `:<version>` does not: a new build, tested,
  scanned, copied, checked, attested, signed and tagged. If the scan now fails, because a fixable
  vulnerability was published since, **the version is abandoned**: its tag stays, with no image, and
  the fix goes out as a higher version.

There is no cleanup step and the tag is never deleted. A wrong release (the wrong commit, a bad
build) is answered with a new version, not a moved tag. The two stop rows of the table are for a
human: find out where the image came from, and release a higher version.

## Recovery guarantees

**A published artifact is never replaced, and it is reused only once it is proven to be this
run's.** A new image is copied to GHCR by digest with no tag, attested and signed, and only then
tagged `:<version>`, so a version tag only ever points at a digest this workflow tested, scanned,
attested and signed; an untagged digest left by a failed run is inert. A reused image must pass
`gh attestation verify … --source-ref refs/heads/main --source-digest <commit>` and carry this
workflow's own cosign signature (identity
`https://github.com/leinardi/herdquay/.github/workflows/release.yaml@refs/heads/main`, issuer
`https://token.actions.githubusercontent.com`). The GitHub release is created as a draft if it does
not exist, and one carrying any asset stops the run, since this workflow never uploads one.

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
image by its own digest with the release's Trivy version, command and ignore file. A finding fails
the run. The published image is immutable, so the fix is a new release, or a reviewed entry in the
ignore file.

## What the workflows trust

**Every action is pinned to a full commit SHA**, with the version in a trailing comment; Dependabot
updates them. **Every image the release job runs is pinned by digest**: the job-local registry and
skopeo in the workflow's `env`, and the Dockerfile frontend (`# syntax=…@sha256:…`). Dependabot does
not update those, nor `SVU_VERSION`, `GO_VERSION` (which only builds svu) and `TRIVY_VERSION` (in
both `release.yaml` and `scheduled-scan.yaml`): bump them by hand, resolving a new digest with
`docker buildx imagetools inspect <image>:<tag>`. The base image is pinned by tag on purpose
([updating.md](updating.md#base-image)).

**Workflow tokens are read-only by default.** Each workflow sets `permissions: contents: read` at
the top; only the release job adds `contents: write`, `packages: write`, `id-token: write` and
`attestations: write`. The image build reads the BuildKit layer cache (`cache-from: type=gha`) of
the `main` scope, which the pre-commit warm-up workflow can also write: keep the pins of the
reusable workflows it calls current.

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
