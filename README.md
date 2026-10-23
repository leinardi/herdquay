# HerdQuay

A persistent, remotely accessible AI coding environment for a homelab: one container that runs a
[Herdr](https://herdr.dev) server, [Claude Code](https://code.claude.com), an unprivileged SSH
server, Git, the GitHub CLI and the toolchains needed to work on the owner's projects.

- **Desktop (Linux, macOS):** the local Herdr client attaches to the container's Herdr server over
  SSH, with the full interactive Claude Code terminal UI.
- **Mobile:** Claude Code [Remote Control](https://code.claude.com/docs/en/remote-control)
  continues the same live conversations from the Claude app or a browser.
- **Persistence:** closing the desktop client leaves every session running. The home directory,
  Claude's login and history, Herdr's state, the SSH host key and the workspace live on volumes,
  so they survive the container being recreated.

## Status

Under construction. The repository scaffolding is in place; the image, its Compose harness, the
smoke tests and the operations docs follow. Nothing is published yet, and deploying it to the
homelab is a separate, later step.

## Design principles

- A [Docker Hardened Image](https://docs.docker.com/dhi/) Debian base (`dhi.io/debian-base`),
  pinned by digest.
- No root at runtime: SSH, Herdr and Claude run as one unprivileged user, UID:GID 568:568.
- Nothing secret in the image or in Git: the GitHub SSH key and token arrive as secret files at
  run time.
- No Docker socket, no read-write Docker API, no published web port.
- Every downloaded tool pinned and verified against its upstream checksum or signature.

## Development

```bash
make pre-commit-install  # installs the pre-commit and commit-msg hooks
make check               # every hook over every file, the same run as CI's pre-commit-all
make help                # lists every target
```

The hooks cover the Dockerfile (hadolint, a system binary: install it locally), the Compose
harness (dclint), shell (shellcheck), the workflows (actionlint), YAML, Markdown, the Makefile and
the MIT license headers. See [AGENTS.md](AGENTS.md) for the conventions and the validation matrix.

## Credits

The SSH and Herdr setup follows ideas from [rozsival/devbox](https://github.com/rozsival/devbox)
(MIT). Any file adapted from it says so in its header.

## License

[MIT](LICENSE)
