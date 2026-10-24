# HerdQuay

A persistent, remotely accessible AI coding environment for a homelab: one container that runs a
[Herdr](https://herdr.dev) server, [Claude Code](https://code.claude.com),
[opencode](https://opencode.ai), an unprivileged SSH server, Git, the GitHub CLI and the
toolchains needed to work on the owner's projects.

- **Desktop (Linux, macOS):** the local Herdr client attaches to the container's Herdr server over
  SSH, with the full interactive Claude Code terminal UI.
- **Mobile:** Claude Code [Remote Control](https://code.claude.com/docs/en/remote-control)
  continues the same live conversations from the Claude app or a browser.
- **Persistence:** closing the desktop client leaves every session running. The home directory,
  Claude's login and history, Herdr's state, the SSH host key and the workspace live on volumes,
  so they survive the container being recreated.

## Status

The image works and is tested locally: desktop attach over SSH, Remote Control from the phone,
sessions that survive a client disconnect and resume after a container restart with no client
attached, and the toolchains of the owner's projects. Nothing is published yet
([deployment](docs/deployment.md) lists what a deployment must provide).

## Quick start (local)

```bash
make local-secrets       # authorizes your ~/.ssh public key
make compose-up          # builds and starts it; SSH on 127.0.0.1:2222
make image-test          # smoke and supervision tests
```

Then connect with Herdr and log in to Claude: [docs/operations.md](docs/operations.md). For
GitHub, set up a GitHub App ([GitHub App](docs/operations.md#github-app)).

## Documentation

- [Operations](docs/operations.md): interface, the GitHub App, commit signing, first connection,
  restarts, `herdquay doctor`, upgrades, recovery.
- [Security model](docs/security.md): boundaries, secrets, accepted risks, supply chain.
- [Development environment](docs/dev-environment.md): the toolchains, the projects they were
  chosen from, what does not run inside.
- [Updating](docs/updating.md): every pin, how to bump it.
- [Docker access](docs/docker-diagnostics.md): why there is no Docker API, and the options.
- [Deployment](docs/deployment.md): what any deployment must provide.
- [Comparison with rozsival/devbox](docs/devbox-comparison.md).

## Design principles

- An Ubuntu 26.04 LTS base (`ubuntu:26.04`), pinned by tag so the official image's security
  rebuilds are picked up: the owner's desktop release, close to GitHub's Ubuntu runners.
- No root at runtime: SSH, Herdr and Claude run as one unprivileged user, UID:GID 568:568.
- Nothing secret in the image or in Git: the GitHub App's private key arrives as a secret file at
  run time, and Git and `gh` use short-lived installation tokens minted from it, over HTTPS only.
- No Docker socket, no read-write Docker API, no published web port.
- Every downloaded tool pinned and verified against its upstream checksum or signature.

## Development

```bash
make pre-commit-install  # installs the pre-commit and commit-msg hooks
make check               # every hook over every file, the same run as CI's pre-commit-all
make help                # lists every target
```

The hooks cover the Dockerfile ([droast](https://github.com/immanuwell/dockerfile-roast), built by
pre-commit with `cargo`, and running a local `shellcheck`), the Compose harness (dclint), shell
(shellcheck), the workflows (actionlint), YAML, Markdown, the Makefile and the MIT license headers.
See [AGENTS.md](AGENTS.md) for the conventions and the validation matrix.

## Credits

The SSH and Herdr setup and the GitHub App credential helper follow ideas from
[rozsival/devbox](https://github.com/rozsival/devbox) (MIT). Any file adapted from it says so in
its header.

## License

[MIT](LICENSE)
