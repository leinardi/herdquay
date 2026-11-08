# Contributing

## Setup

You need:

- Docker with Buildx, to build and test the image;
- `cargo`, since pre-commit builds the Dockerfile linter (droast) from source, and a
  [`shellcheck`](https://www.shellcheck.net/) on `PATH`, which droast runs on the `RUN` scripts;
- [`pre-commit`](https://pre-commit.com/). Install the hooks once with `make pre-commit-install`:
  it installs both the `pre-commit` and the `commit-msg` hooks, so commit messages are checked
  when you commit.

Then:

- `make check` runs the full pre-commit suite on every file, `make check-stage` on the staged
  files only;
- `make image-build` builds `herdquay:local`, `make image-test` runs the smoke and supervision
  suites against it, and `make image-release-smoke` the release's short smoke test;
- `make compose-up` starts the local harness on `127.0.0.1:2222` (run `make local-secrets` first);
- `make help` lists every target.

Read [AGENTS.md](AGENTS.md) for the layout, the conventions and the validation matrix a change
must pass, and [docs/updating.md](docs/updating.md) before bumping a pinned tool or the base image.

## Commit messages

All commits must follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
with a scope: `<type>(<scope>)[!]: <description>`. The `conventional-pre-commit` hook enforces this
on `commit-msg`, and the `conventional-commits` CI job checks it again on every pull request.

```text
fix(image): bump gh to 2.80.0
feat(image): add the Rust toolchain
docs(readme): fix a link
```

The release version is derived from these types, since the last release:

| Release | Commit | Example |
| --- | --- | --- |
| major | any type with `!` before the colon, or a `BREAKING CHANGE:` footer | `feat(image)!: move the home volume` |
| minor | `feat` | `feat(image): add the Rust toolchain` |
| patch | `fix` | `fix(image): bump gh to 2.80.0` |
| none | everything else: `build`, `chore`, `ci`, `docs`, `perf`, `refactor`, `style`, `test`, `revert` | `docs(readme): fix a link` |

Pick the type by whether the change should ship in a release, not by what kind of change it is. A
`revert` of a shipped `feat` or `fix` is itself a `fix`. The version tool matches `feat` and `fix`
anywhere before the colon (`prefix:` counts as `fix:`), so keep such words out of other subjects.

Pull requests are merged with merge commits; squash and rebase merging are disabled. Every commit
therefore lands on `main` as it is, so each one needs a correct type, not just the pull request as a
whole.

## Releasing

Dispatch the **Release herdquay** workflow from `main`, once CI has run on the commit's push. Leave
the version empty to derive it from the commits, or pass one (e.g. `1.2.0` or `v1.2.0`); tick *dry
run* first to see what it would do. The first release needs an explicit version, since there is no
tag to derive it from. The workflow waits for CI to pass on the commit, builds the image once,
tests and scans it, and only then tags the version and publishes the image to GHCR, attested and
signed. Tags are immutable: a wrong release is answered with a higher version. A failed run is
finished by re-running it. [docs/release.md](docs/release.md) has the details and the recovery
procedures.
