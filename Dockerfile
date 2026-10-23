# syntax=docker/dockerfile:1
#
# MIT License
#
# Copyright (c) 2026 Roberto Leinardi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# The DHI Debian 13 dev variant: the only DHI Debian image with apt and a shell, which an
# interactive environment needs. Pinned by tag, not digest: DHI rebuilds it far too often for a
# digest pin to be maintainable, and every rebuild is a security update we want.
ARG BASE_IMAGE=dhi.io/debian-base:trixie-dev

# -------------------------------------------------------------------------------------------------
# fetch: downloads and verifies every artifact that does not come from apt. Nothing from this
# stage reaches the final image except the verified binaries.
# -------------------------------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS fetch

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl gnupg jq \
	&& rm -rf /var/lib/apt/lists/*

# Herdr publishes neither a checksum file nor a signature: the digest is the release asset's, from
# gh api repos/herdrdev/herdr/releases/tags/v<version> (docs/updating.md).
ARG HERDR_VERSION=0.9.5
ARG HERDR_SHA256=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d
RUN curl -fsSL -o /tmp/herdr \
	"https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64" \
	&& echo "${HERDR_SHA256}  /tmp/herdr" | sha256sum --check --strict - \
	&& install -D -m 0755 /tmp/herdr /usr/local/bin/herdr

# Claude Code: the release manifest is signed by Anthropic's release key (vendored in
# container/keys, its fingerprint pinned here), and the manifest carries the binary's checksum.
# install.sh checks the checksum but not the signature, so both are checked here instead.
ARG CLAUDE_VERSION=2.1.308
ARG CLAUDE_SIGNER_FINGERPRINT=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
COPY container/keys/claude-code.asc /tmp/claude-code.asc
RUN base="https://downloads.claude.ai/claude-code-releases/${CLAUDE_VERSION}" \
	&& curl -fsSL -o /tmp/manifest.json "${base}/manifest.json" \
	&& curl -fsSL -o /tmp/manifest.json.sig "${base}/manifest.json.sig" \
	&& GNUPGHOME="$(mktemp -d)" && export GNUPGHOME \
	&& gpg --batch --quiet --import /tmp/claude-code.asc \
	&& gpg --batch --status-fd 1 --verify /tmp/manifest.json.sig /tmp/manifest.json \
		| grep -q "^\[GNUPG:\] VALIDSIG ${CLAUDE_SIGNER_FINGERPRINT} " \
	&& test "$(jq -r .version /tmp/manifest.json)" = "${CLAUDE_VERSION}" \
	&& checksum="$(jq -r '.platforms["linux-x64"].checksum' /tmp/manifest.json)" \
	&& curl -fsSL -o /tmp/claude "${base}/linux-x64/claude" \
	&& echo "${checksum}  /tmp/claude" | sha256sum --check --strict - \
	&& install -D -m 0755 /tmp/claude /usr/local/bin/claude

# -------------------------------------------------------------------------------------------------
# final
# -------------------------------------------------------------------------------------------------
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The unprivileged user everything runs as. 568:568 is the homelab's apps user, so the image works
# on its datasets unchanged; override at build time for another host.
ARG HERDQUAY_UID=568
ARG HERDQUAY_GID=568

# python3 is needed by Herdr's Claude integration hook, which reports each conversation's session id
# so it can be resumed after a restart. openssh-server's postinst generates host keys; they are deleted, because the real host key is
# generated once at run time on the persistent home volume.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		bash-completion \
		ca-certificates \
		curl \
		git \
		iproute2 \
		jq \
		less \
		ncurses-term \
		openssh-client \
		openssh-server \
		procps \
		python3 \
		tini \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -f /etc/ssh/ssh_host_*

# The DHI base has no useradd (no passwd package), so the account is written directly. No password
# hash: sshd only accepts keys, and the account has no sudo.
RUN echo "herdquay:x:${HERDQUAY_GID}:" >>/etc/group \
	&& echo "herdquay:x:${HERDQUAY_UID}:${HERDQUAY_GID}:HerdQuay:/home/herdquay:/bin/bash" >>/etc/passwd \
	&& install -d -m 0755 -o "${HERDQUAY_UID}" -g "${HERDQUAY_GID}" /home/herdquay \
	&& install -d -m 0755 -o "${HERDQUAY_UID}" -g "${HERDQUAY_GID}" /home/herdquay/workspace

COPY --from=fetch /usr/local/bin/herdr /usr/local/bin/claude /usr/local/bin/
COPY container/etc/ /etc/
COPY container/bin/ /usr/local/bin/
COPY container/share/ /usr/local/share/

ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown
LABEL org.opencontainers.image.title="HerdQuay" \
	org.opencontainers.image.description="Persistent, remotely accessible Herdr + Claude Code development environment" \
	org.opencontainers.image.source="https://github.com/leinardi/herdquay" \
	org.opencontainers.image.version="${VERSION}" \
	org.opencontainers.image.revision="${REVISION}" \
	org.opencontainers.image.created="${CREATED}" \
	org.opencontainers.image.licenses="MIT"

ENV HOME=/home/herdquay \
	USER=herdquay \
	SHELL=/bin/bash \
	LANG=C.UTF-8 \
	DISABLE_AUTOUPDATER=1

USER ${HERDQUAY_UID}:${HERDQUAY_GID}
WORKDIR /home/herdquay

EXPOSE 2222

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
	CMD ["/usr/local/bin/herdquay-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/herdquay-entrypoint"]
