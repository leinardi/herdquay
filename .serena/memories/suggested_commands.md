# Commands

- `make check`: pre-commit on all files (= CI `pre-commit-all`). `make check-stage`: staged only.
- `make pre-commit-install`: pre-commit + commit-msg hooks.
- `make image-build`: builds `herdquay:local`. `make image-test`: `image-smoke` + `image-supervision` (needs Docker; first start downloads Claude Code).
- `make local-secrets`, then `make compose-up` (harness on 127.0.0.1:2222), `compose-logs`, `compose-down`. With the App: `scripts/local-secrets.sh --github-app-key <pem> [--git-signing-key <asc>]` and `HERDQUAY_GITHUB_APP_ID=… make compose-up`.
- `make mk-common-update`: refresh vendored make snippets. `make help`: all targets.
- Inside the container: `herdquay doctor [--network]`.
- License header year for a file: `git log --diff-filter=A --follow --format=%ad --date=format:%Y -- <file> | tail -1`.
