# Tech stack

- Bash scripts everywhere (container/bin, scripts, tests); one Python stdlib-only test stub (`tests/github-stub.py`, uses `openssl` subprocess for RS256 verify).
- Docker/Buildx, Docker Compose (local harness only), tini as PID 1.
- Make with shared snippets from `leinardi/make-common@v1` fetched into `.mk/` (`help.mk`, `pre-commit.mk`, `password.mk`, `.mk-common-version`, `scripts/bootstrap-mk-common.sh`: vendored, never hand-edit). Project targets only in local `.mk/*.mk` listed in `MK_LOCAL_FILES`.
- pre-commit hooks: checkmake, actionlint, markdownlint-cli2, shellcheck, prettier (YAML), yamllint, dclint, droast (Dockerfile Roast, built from source: needs `cargo`), license-header check. ShellCheck must be on PATH at the release `.github/actions/setup-shellcheck` pins.
- Base `ubuntu:26.04` pinned by tag (not digest). Pins and bump procedure: `docs/updating.md`; `make check-updates` reports newer releases.
- In-image tools used by scripts: curl, jq, openssl, gnupg, flock (util-linux), python3.
