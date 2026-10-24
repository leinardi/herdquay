# Security policy

## Supported versions

Only the latest release gets security fixes. Released `vX.Y.Z` tags and their images are
immutable and never re-pointed: a fix ships as a new version
([docs/release.md](docs/release.md)).

The image never contains credentials. A report about a secret leaking out of a running container
(SSH keys, the GitHub App's private key or its installation tokens, the Git signing key, Claude
or opencode credentials) is in scope; see [docs/security.md](docs/security.md) for the threat
model and the risks that are accepted on purpose.

## Reporting a vulnerability

Report it privately through GitHub's
[private vulnerability reporting](https://github.com/leinardi/herdquay/security/advisories/new),
not in a public issue or pull request. Include the affected version, how to reproduce it, and what
an attacker gains.

This is a project maintained in spare time, so reports are handled on a best-effort basis. You will
get an answer in the advisory, and the fix, once released, is credited there unless you prefer
otherwise.
