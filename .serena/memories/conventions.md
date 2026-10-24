# Conventions

Shell:
- `#!/usr/bin/env bash`, MIT header (year of first commit; adapted-from-devbox files add `Copyright (c) 2026 Vít Rozsíval`), then a prose comment block describing usage/behavior, then `set -euo pipefail`. Tabs for indentation; `${var}` braces; `[[ ]]`.
- Scripts whose functions are called via `$(...)` add `shopt -s inherit_errexit`; never pass `"$(cmd)"` directly as an argument when failure must stop (assign first).
- Secrets/tokens never on a command line (curl gets auth via `-K -` on stdin). Files in shared `/tmp`: check `-O` and not a symlink; atomic writes via mktemp + mv; umask 077.
- Tests: avoid `cmd | grep -q` under pipefail (SIGPIPE flips the result); capture output then `grep <<<"${out}"`. Use bash's `test -r`, not `/usr/bin/test` (Ubuntu 26.04 Rust coreutils ignore ACLs).
- License header governed for shell, Dockerfiles, Makefile, local `.mk`; never YAML/JSON/Markdown.

Workflows: actions pinned by full SHA with `# vX.Y.Z`; top-level `permissions: contents: read`; `${{ }}` only via `env:`; files `.yaml`; new gating job goes into `ci-result` needs.

Markdown: prose wrapped at 100 cols; never wrap tables, code blocks, link targets.

Commits: Conventional Commits with mandatory scope `type(scope): desc`. Type chosen by whether it should ship: `feat`/`fix` ship (svu derives version), `perf`/`refactor`/`docs`/`ci`/`chore`/`test`/`style`/`revert` do not. Avoid a word ending in feat/fix right before a colon. PRs land as merge commits: every commit counts.
