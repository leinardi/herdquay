#!/usr/bin/env bash
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
#
# Reports every tool the Dockerfile pins whose upstream has a newer release, with what a bump
# needs (docs/updating.md). Read-only: it never edits the Dockerfile. Needs curl, jq and an
# authenticated gh (GitHub API rate limits).
#
# Usage: scripts/check-updates.sh

set -euo pipefail

DOCKERFILE="$(git rev-parse --show-toplevel)/Dockerfile"
outdated=0

pinned() {
	sed -n "s/^ARG $1=//p" "${DOCKERFILE}" | head -n 1
}

report() {
	local name="$1" current="$2" latest="$3" hint="${4:-}"
	if [[ -z ${latest} ]]; then
		printf '  ?     %-16s %s (could not read the latest release)\n' "${name}" "${current}"
	elif [[ ${current} == "${latest}" ]]; then
		printf '  ok    %-16s %s\n' "${name}" "${current}"
	else
		printf '  bump  %-16s %s -> %s%s\n' "${name}" "${current}" "${latest}" "${hint:+  (${hint})}"
		outdated=$((outdated + 1))
	fi
}

# The latest release's tag as published: most carry a leading v, droast's do not.
github_latest_tag() {
	gh api "repos/$1/releases/latest" --jq .tag_name 2>/dev/null
}

github_digest() {
	gh api "repos/$1/releases/tags/$2" --jq ".assets[] | select(.name == \"$3\") | .digest" 2>/dev/null |
		sed 's/^sha256://'
}

check_github() {
	local name="$1" repo="$2" arg="$3" asset_pattern="$4" note="${5:-}" current tag latest asset
	current="$(pinned "${arg}")"
	tag="$(github_latest_tag "${repo}")"
	latest="${tag#v}"
	asset="${asset_pattern//\{v\}/${latest}}"
	report "${name}" "${current}" "${latest}" \
		"${arg%_VERSION}_SHA256=$(github_digest "${repo}" "${tag}" "${asset}")${note:+; ${note}}"
}

echo "Release binaries"
check_github herdr herdrdev/herdr HERDR_VERSION herdr-linux-x86_64
check_github chezmoi twpayne/chezmoi CHEZMOI_VERSION chezmoi-linux-amd64
check_github gh cli/cli GH_VERSION 'gh_{v}_linux_amd64.tar.gz'
check_github golangci-lint golangci/golangci-lint GOLANGCI_LINT_VERSION 'golangci-lint-{v}-linux-amd64.tar.gz' \
	"matches the projects' pre-commit rev: bump with them"
check_github goreleaser goreleaser/goreleaser GORELEASER_VERSION goreleaser_Linux_x86_64.tar.gz \
	"matches monmux's release workflow: bump with it"
check_github droast immanuwell/dockerfile-roast DROAST_VERSION droast-linux-x86_64 \
	"the projects pin it in their hooks and setup-droast: bump with them"
check_github shellcheck koalaman/shellcheck SHELLCHECK_VERSION 'shellcheck-v{v}.linux.x86_64.tar.xz' \
	"the projects' setup-shellcheck pins it: bump with them"
check_github yq mikefarah/yq YQ_VERSION yq_linux_amd64

echo "Toolchains"
current="$(pinned CLAUDE_VERSION)"
report claude "${current}" "$(curl -fsSL https://downloads.claude.ai/claude-code-releases/stable 2>/dev/null)" \
	"stable channel; the build verifies the signed manifest"
go_line="$(pinned GO_VERSION | cut -d. -f1-2)"
go_latest="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' 2>/dev/null |
	jq -r --arg line "go${go_line}." '[.[] | select(.stable and (.version | startswith($line)))][0].version // empty' |
	sed 's/^go//')"
report "go ${go_line}" "$(pinned GO_VERSION)" "${go_latest}" \
	"GO_SHA256 from https://go.dev/dl/?mode=json&include=all; a new minor line only when the projects move to it"
node_line="$(pinned NODE_VERSION | cut -d. -f1)"
node_latest="$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null |
	jq -r --arg line "v${node_line}." '[.[] | select(.version | startswith($line))][0].version // empty' | sed 's/^v//')"
report "node ${node_line}" "$(pinned NODE_VERSION)" "${node_latest}" \
	"NODE_SHA256 from https://nodejs.org/dist/v${node_latest}/SHASUMS256.txt"
report pre-commit "$(pinned PRE_COMMIT_VERSION)" \
	"$(curl -fsSL https://pypi.org/pypi/pre-commit/json 2>/dev/null | jq -r '.info.version // empty')" \
	"keep it in step with the projects' CI pin"
opencode="$(curl -fsSL https://registry.npmjs.org/@opencode%2fcli-linux-x64/latest 2>/dev/null || true)"
report opencode "$(pinned OPENCODE_VERSION)" "$(jq -r '.version // empty' <<<"${opencode}" 2>/dev/null)" \
	"OPENCODE_INTEGRITY=$(jq -r '.dist.integrity // empty' <<<"${opencode}" 2>/dev/null); npm, not GitHub (that is opencode 1)"
rustup_latest="$(curl -fsSL https://static.rust-lang.org/rustup/release-stable.toml 2>/dev/null |
	sed -n "s/^version = '\\(.*\\)'$/\\1/p")"
report rustup "$(pinned RUSTUP_VERSION)" "${rustup_latest}" \
	"RUSTUP_SHA256 from https://static.rust-lang.org/rustup/archive/${rustup_latest}/x86_64-unknown-linux-gnu/rustup-init.sha256; only the installer: rustup updates itself"
report "rust (minimum)" "$(pinned RUST_MINIMUM)" \
	"$(curl -fsSL https://static.rust-lang.org/dist/channel-rust-stable.toml 2>/dev/null |
		sed -n '/^\[pkg.rustc\]/,/^version/s/^version = "\([0-9.]*\) .*/\1/p')" \
	"a minimum: rustup update moves the home volume above it without a new image"
report playwright "$(pinned PLAYWRIGHT_VERSION)" \
	"$(curl -fsSL https://registry.npmjs.org/playwright/latest 2>/dev/null | jq -r '.version // empty')" \
	"bump only when bitgauge and runhold bump @playwright/test"

echo "Docker CLI (apt, download.docker.com ubuntu resolute stable)"
packages="$(curl -fsSL https://download.docker.com/linux/ubuntu/dists/resolute/stable/binary-amd64/Packages 2>/dev/null || true)"
docker_latest() {
	awk -v pkg="$1" '$1 == "Package:" { p = $2 } $1 == "Version:" && p == pkg { print $2 }' <<<"${packages}" |
		sort -V | tail -n 1
}
report docker-ce-cli "$(pinned DOCKER_CLI_VERSION)" "$(docker_latest docker-ce-cli)"
report docker-buildx "$(pinned DOCKER_BUILDX_VERSION)" "$(docker_latest docker-buildx-plugin)"
report docker-compose "$(pinned DOCKER_COMPOSE_VERSION)" "$(docker_latest docker-compose-plugin)"

echo
if ((outdated)); then
	echo "${outdated} pin(s) can be bumped: edit the ARGs (and their digests), then make image-build image-test projects-test."
else
	echo "Every pin is current."
fi
