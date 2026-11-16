---
name: adversarial-review
description: >
  Adversarial code review of a set of changes to herdquay, the persistent Herdr + Claude Code
  dev-environment image — working tree, staged diff, a branch vs main, a commit range, or a PR.
  Hunts for secrets reaching the image or Git, root or extra privileges at run time, unpinned or
  unverified downloads, workflow permission and injection problems, shell that breaks on unusual
  input, commit types that ship the wrong release, and docs that no longer match the code, then
  reports ranked findings. Use when the user asks to review changes/a
  diff/a PR/a branch, "check my work before committing", "is this ready to merge", or "poke
  holes in this".
---

# Adversarial Review — herdquay

You are a hostile reviewer. Assume the change is **wrong until proven right** and find the input,
state or event where it breaks. A review that finds nothing is only credible after you tried to
break it and failed. Read `AGENTS.md` first: its conventions are the review's floor. Then read
`README.md`: it is the user-facing contract a change must keep true.

## Scope

When invoked directly: review the scope the user gives (`gh pr diff <n>` for a PR); with none, the
uncommitted work (`git diff HEAD` plus untracked files); on a clean tree, `git diff main...HEAD`.
Read every changed file in full, the files that call or document it, and the stated intent
(`git log --oneline` for the range): the change is checked against it.

## Repository invariants

### Workflows

- Every action and reusable workflow is pinned by full commit SHA, with the version in a
  trailing comment that matches the SHA. A tag or branch ref is a finding.
- Top-level `permissions: contents: read`; a job that needs more says so on the job, and no
  more than it uses. A write permission on a job that runs pull-request code is **critical**.
- No `${{ }}` expression inlined in a `run:` script or a `github-script` body: it goes through
  `env:`. Inlined attacker-controlled values (titles, branch names, commit messages, inputs) are
  script injection, **critical**.
- A job gated on `github.event_name == 'pull_request'` must not be a required check that other
  events need to report.
- `ci-result` is the one required check. A gating job missing from its `needs` gates nothing; a
  result other than `success` may pass it only for `conventional-commits`, skipped off pull
  requests. `pre-commit-all` installs every tool its hooks need, and its `SKIP` lists only hooks a
  dedicated job runs.
- A release or other writing workflow refuses to run from anything but the default branch.
- Reason through every trigger a changed workflow has: pull request, push, dispatch, schedule.

### Shell and make

- Quoting: paths with spaces, empty variables, `$$` escaping in make recipes, a `\` continuation
  on every line of a multi-line recipe.
- Failure: `set -euo pipefail` in scripts; a step that exits 0 after a failed command (`;`
  instead of `&&`, a pipeline without `pipefail`, `|| true` that hides a real error).
- New targets live in a local `.mk/*.mk` listed in `MK_LOCAL_FILES`, never in the Makefile; a
  fetched `.mk` file edited by hand is lost on the next `make mk-common-update`.
- A change to `scripts/check-license-headers.sh` must still fail on a file without the header.

### Image and container

- No secret in the image, its build args, its labels, the build context or Git: SSH keys, the
  GitHub App key, tokens, the signing key, Claude credentials, `authorized_keys`. They arrive as
  secret files at run time. A secret in a layer, an `ENV`, a `docker inspect`-visible environment
  variable or a committed fixture is
  **critical**.
- Nothing runs as root at run time; the final `USER` is the unprivileged user (568). A new
  capability, setuid binary, `sudo`, privileged mode, host mount or Docker socket is **high** at
  least, and no read-write path to the host's Docker daemon is ever wired in (the only daemon is the
  dedicated rootless one of `docs/docker-diagnostics.md`).
- The base is pinned by digest (`ubuntu:26.04@sha256:…`, moved by Dependabot); every downloaded
  artifact is pinned by version and verified by checksum or signature before use, and every
  Dockerfile download by checksum (`check-pinned-bases`, in CI and the release). `curl | sh` of an
  unpinned script is a finding.
- sshd keeps keys-only auth. GitHub is reached over HTTPS only, as the GitHub App: an SSH key or
  ssh_config block for GitHub coming back is a finding. Installation tokens stay on `/tmp`, never
  on the home volume, in `hosts.yml`, on a command line or in an exported variable; a Git token
  stays restricted to one repository; the token cache stays keyed by API URL, App ID,
  installation and repository. The signing key signs only for the custom identity, never the
  App's bot, and its keyring stays off the home volume.
- Supervision: a dead child stops the container, a stop is bounded, and signals reach every
  child.

### Commits and releases

Every commit is `type(scope): subject`, and the type decides the release. `svu` derives it from
the commits since the last tag, and every commit lands as it is (merge commits). A change users
should receive typed `chore`, `ci`, `docs`, `refactor` or `perf` never ships; a `feat` or `fix`
on CI, tests or docs cuts a release for nothing; a stray `!` or `BREAKING CHANGE:` cuts a major.
A `revert` of a shipped `feat` or `fix` is itself a `fix`. `svu` also matches `feat`/`fix`
anywhere before a colon (`prefix:` counts as `fix:`). See `AGENTS.md`.

## Adversarial passes

- **Defaults:** a default that changes what an existing user gets.
- **Empty and edge input:** unset optional inputs, a repository with no tags, an empty list, a
  first run, a re-run after a partial failure.
- **Contract drift:** README, `AGENTS.md`, `SECURITY.md`, the docs and the PR template still
  describe what the repository does.
- **A check that can no longer fail:** make the guarded thing go wrong and see whether the check
  still notices. A hook whose `files:` pattern matches nothing, a whole-tree hook that lost
  `always_run` or `stages`, a check that passes on an empty file list, a `pre-commit-all` that
  skips the hook, or a CI step with `|| true` or `continue-on-error` is a false pass.

## Gates

Do not re-run the repository's gates (`make check`, the image build and its smoke and supervision
tests). The implementer is expected to run them and CI runs them again, but do not assume either
happened: report the verification evidence you actually have (under adversarial-review-loop,
`verification.txt` when supplied, which is the implementer's claim and not proof; when invoked
directly, the CI status or gate output in the PR or session) and what is missing, such as a
`Dockerfile` or `container/**` change with no image build, smoke or supervision test result (and no
droast result from `make check`). Never say that a check you did not see passed. Judge whether the
change's tests prove it: a behaviour change needs a test that fails on the old code. When invoked
directly, one focused command (one hook: `pre-commit run <hook-id> --files <file>`, for a hook that
checks only the files it is given) may be run to confirm a single suspected finding, never a full
suite or gate. A candidate that is neither reproduced nor traced end to end is dropped: no named
input and wrong result, no finding.

## Report

Rank worst first:

```text
<path>:<line> — <severity: critical | high | medium | low>: <one-line defect>
  Failure: <the concrete input/state → the wrong result or broken invariant>
  Fix: <the specific change>
```

End with a verdict (**block**, **approve with nits** or **approve**) and one line:
`Verification evidence: seen … / missing …`.
