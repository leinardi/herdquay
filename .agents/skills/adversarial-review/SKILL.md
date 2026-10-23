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

You are a hostile reviewer. Assume the change is **wrong until proven right**. Find the input,
state or event where it breaks. A review that finds nothing is only credible after you tried to
break it and failed.

Copy this checklist and tick items as you go:

```text
Review progress:
- [ ] 1. Diff and intent established (default scope if none given)
- [ ] 2. AGENTS.md and the contracts it names read
- [ ] 3. Repository invariants checked
- [ ] 4. Adversarial passes run
- [ ] 5. Findings confirmed or dropped; gates run
- [ ] 6. Report written
```

## 1. Establish the diff

With no scope given, review the uncommitted work; if the tree is clean, review the branch
against `main`.

| User intent | Command |
| --- | --- |
| "my work" / uncommitted | `git status`, then `git diff HEAD`; read untracked files too |
| staged changes only | `git diff --staged` |
| a branch / "this PR" | `git diff main...HEAD` |
| a commit range | `git diff <base>..<head>` |
| a GitHub PR number | `gh pr diff <n>` and `gh pr view <n>` |

Read `git log --oneline` for the range: the stated intent is what the change is checked against,
and a commit type that ships the wrong version is a finding too (pass in §4). Read every changed
file in full, not just the hunks, and the files that call or document it.

## 2. Load project authority

Read `AGENTS.md` first: its conventions are the review checklist's floor, and `README.md` is the
user-facing contract a change must keep true.

## 3. Repository invariants — check on every review

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

### Shell and make

- Quoting: paths with spaces, empty variables, `$$` escaping in make recipes, a `\` continuation
  on every line of a multi-line recipe.
- Failure: `set -euo pipefail` in scripts; a step that exits 0 after a failed command (`;`
  instead of `&&`, a pipeline without `pipefail`, `|| true` that hides a real error).
- New targets live in a local `.mk/*.mk` listed in `MK_LOCAL_FILES`, never in the Makefile; a
  fetched `.mk` file edited by hand is lost on the next `make mk-common-update`.

### Image and container

- No secret in the image, its build args, its labels, the build context or Git: SSH keys, tokens,
  Claude credentials, `authorized_keys`. They arrive as secret files at run time. A secret in a
  layer, an `ENV`, a `docker inspect`-visible environment variable or a committed fixture is
  **critical**.
- Nothing runs as root at run time; the final `USER` is the unprivileged user (568). A new
  capability, setuid binary, `sudo`, privileged mode, host mount or Docker socket is **high** at
  least, and a read-write Docker API proxy is never wired in.
- The base is pinned by tag (`ubuntu:26.04`); every downloaded artifact is pinned by version and
  verified by checksum or signature before use. `curl | sh` of an unpinned script is a finding.
- sshd keeps keys-only auth and host-key verification stays on in the client config; Git uses
  `StrictHostKeyChecking yes`.
- Supervision: a dead child stops the container, a stop is bounded, and signals reach every
  child.

### Commits and releases

- Every commit is `type(scope): subject`. The type decides the release (pass in §4).

## 4. Adversarial passes

- **Correctness:** a default that changes what an existing user gets.
- **Empty and edge input:** unset optional inputs, a repository with no tags, an empty list, a
  first run, a re-run after a partial failure.
- **Contract drift:** README, `AGENTS.md`, `SECURITY.md`, the docs and the PR template still
  describe what the repository does.
- **Commit type matches whether it ships:** `svu` derives the release from the commits since the
  last tag, and every commit lands as it is (merge commits). A change users should receive typed
  `chore`, `ci`, `docs`, `refactor` or `perf` never ships; a `feat` or `fix` on CI, tests or docs
  cuts a release for nothing; a stray `!` or `BREAKING CHANGE:` cuts a major. A `revert` of a
  shipped `feat` or `fix` is itself a `fix`. `svu` also matches `feat`/`fix` anywhere before a
  colon (`prefix:` counts as `fix:`). See `AGENTS.md`.
- **A check that can no longer fail:** a hook, script or CI job guards a claim nobody re-checks by
  hand. Make the guarded thing go wrong and see whether the check still notices. A hook whose
  `files:` pattern matches nothing, a whole-tree hook that lost `always_run` or `stages`, a check
  that passes on an empty file list, a `pre-commit-all` that skips the hook, or a CI step with
  `|| true` or `continue-on-error`, is a false pass: a finding.

For each candidate finding, reproduce it or trace the failing input end to end. If that confirms
it, report it; if not, dig once more, then drop it. No named input and wrong result, no finding.

## 5. Verify

| Diff touched | Run |
| --- | --- |
| anything | `make check` |
| a workflow | `make check` (actionlint), then reason through each trigger it has: pull request, push, dispatch, schedule |
| `scripts/check-license-headers.sh` | the script, once as is and once on a file without the header |
| `Dockerfile`, `container/**` | `make check` (droast), then the image build and its smoke and supervision tests |

Say which gates you could not run rather than implying they passed.

## 6. Report

Rank worst first:

```text
<path>:<line> — <severity: critical | high | medium | low>: <one-line defect>
  Failure: <the concrete input/state → the wrong result or broken invariant>
  Fix: <the specific change>
```

End with a verdict: **block**, **approve with nits**, or **approve**, and the gates you ran.
