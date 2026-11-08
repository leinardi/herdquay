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
# The release's short smoke test of a built image: its labels name the expected version and
# commit, the container starts the way the harness runs it and turns healthy (sshd and the Herdr
# server), an SSH login runs the image's tools, and a requested stop is clean. The full suite
# (smoke.sh, supervision.sh) runs in CI on the same Dockerfile and base digest; this only proves
# that the image the release built starts.
#
# Usage: tests/release-smoke.sh   (HERDQUAY_IMAGE selects the image, default herdquay:local;
# HERDQUAY_EXPECT_VERSION and HERDQUAY_EXPECT_REVISION, when set, must equal its labels)

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

export HERDQUAY_STOP_TIMEOUT=5
# Nothing is downloaded at start: the full smoke test covers the Claude Code and Rust installs.
export HERDQUAY_CLAUDE_INSTALL=0
export HERDQUAY_RUST_INSTALL=0

label() {
	docker image inspect -f "{{ index .Config.Labels \"org.opencontainers.image.$1\" }}" "${IMAGE}"
}

for pair in "version:${HERDQUAY_EXPECT_VERSION:-}" "revision:${HERDQUAY_EXPECT_REVISION:-}"; do
	key="${pair%%:*}" want="${pair#*:}"
	[[ -n ${want} ]] || continue
	got="$(label "${key}")"
	[[ ${got} == "${want}" ]] || die "label org.opencontainers.image.${key} is '${got}', want '${want}'"
	pass "label ${key}: ${got}"
done

make_secrets

name="${TEST_ID}-release"
start_container "${name}" "${name}-home"
wait_healthy "${name}"
pass "container healthy (sshd on 2222, Herdr server running)"

out="$(in_ssh "${name}" 'herdr --version && gh --version && go version && node --version')" ||
	die "the tools do not run over SSH"
pass "SSH login runs the tools: $(tr '\n' ';' <<<"${out}")"

docker stop -t 30 "${name}" >/dev/null
code="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
[[ ${code} == 0 ]] || die "docker stop: exit code ${code}"
pass "docker stop: exit 0"

echo "release-smoke: all checks passed"
