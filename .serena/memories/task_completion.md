# Definition of done

Always: `make check`. Then by what changed (AGENTS.md validation matrix):
- `Dockerfile`, `droast.toml`, `container/**`: `make image-build image-test`; keep `docs/updating.md` and `docs/dev-environment.md` in step.
- `tests/**`, `scripts/local-secrets.sh`: `make image-test`.
- `.github/workflows/**`: `pre-commit run actionlint --all-files`; reason through every trigger.
- `Makefile`/local `.mk`: `make check` + `make help`.
- `scripts/check-license-headers.sh`: strip one header, confirm the hook names the file.
- Vendored make-common files: never edit; port upstream, then `make mk-common-update`.
- Docs/skills: markdownlint, 100-col wrap. Update README/docs when behavior changes.
Reviews: load the `adversarial-review` project skill (`.agents/skills/`, symlinked as `.claude/skills`).
