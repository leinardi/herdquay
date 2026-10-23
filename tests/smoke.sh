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
# Smoke test of a built image: SSH as the unprivileged user, the doctor, the pinned tools, the
# GitHub client configuration, agent forwarding, secret permissions, and persistence of the host
# key and home across container recreation. Needs no network and no real credentials.
#
# Usage: tests/smoke.sh   (HERDQUAY_IMAGE selects the image, default herdquay:local)

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

make_secrets
start_container "${TEST_ID}" "${TEST_ID}-home"
wait_healthy "${TEST_ID}"
pass "container healthy"

[[ $(in_ssh "${TEST_ID}" 'id -u'):$(in_ssh "${TEST_ID}" 'id -g') == 568:568 ]] || die "SSH session is not 568:568"
pass "SSH login as 568:568"

in_ssh "${TEST_ID}" 'herdquay doctor' >"${SCRATCH}/doctor.txt" || {
	cat "${SCRATCH}/doctor.txt" >&2
	die "herdquay doctor failed"
}
pass "herdquay doctor: $(tail -n 1 "${SCRATCH}/doctor.txt")"

root="$(docker exec "${TEST_ID}" ps -o user= -e | sort -u | tr '\n' ' ')"
[[ ${root} == "herdquay " ]] || die "processes run as: ${root}"
pass "every process runs as herdquay"

config="$(in_ssh "${TEST_ID}" 'ssh -G github.com')"
grep -qx 'identityfile /run/secrets/github_ssh_key' <<<"${config}" || die "github.com does not use the secret key"
grep -qx 'stricthostkeychecking true' <<<"${config}" || die "github.com host key checking is not strict"
in_ssh "${TEST_ID}" 'ssh-keygen -F github.com -f /etc/ssh/ssh_known_hosts' | grep -q 'ssh-ed25519' ||
	die "GitHub's host keys are not shipped"
pass "GitHub SSH: secret key, strict host key checking, shipped host keys"

[[ $(in_ssh "${TEST_ID}" 'gh auth token') == github_pat_test_token ]] || die "gh does not read the token file"
in_ssh "${TEST_ID}" 'test ! -e ~/.config/gh/hosts.yml' || die "gh wrote hosts.yml"
[[ $(in_ssh "${TEST_ID}" 'printf "protocol=https\nhost=github.com\n\n" | git credential fill | sed -n "s/^password=//p"') == github_pat_test_token ]] ||
	die "git's HTTPS credential helper does not use the token"
pass "gh and git HTTPS use the token file, nothing stored"

eval "$(ssh-agent -s)" >/dev/null
ssh-add -q "${CLIENT_KEY}"
in_ssh "${TEST_ID}" 'ssh-add -l' -A | grep -q herdquay-test-client || die "agent forwarding does not work"
pass "agent forwarding for manual SSH sessions"

for secret in authorized_keys github_ssh_key github_token; do
	# bash's test, not /usr/bin/test: Ubuntu 26.04's Rust coreutils ignore ACLs in test -r.
	docker exec "${TEST_ID}" bash -c "test -r /run/secrets/${secret}" || die "568 cannot read ${secret}"
	if docker run --rm --user 4242:4242 --entrypoint cat \
		-v "${HERDQUAY_SECRETS_DIR}/${secret}:/run/secrets/${secret}:ro" "${IMAGE}" "/run/secrets/${secret}" >/dev/null 2>&1; then
		die "UID 4242 can read ${secret}"
	fi
done
"${REPO_ROOT}/scripts/local-secrets.sh" --check >/dev/null || die "secret ACLs are not exactly owner + 568"
pass "secrets: readable by 568, not by another UID, ACL exactly owner + 568"

fingerprint="$(in_ssh "${TEST_ID}" 'ssh-keygen -lf ~/.ssh/host/ssh_host_ed25519_key.pub')"
in_ssh "${TEST_ID}" 'echo persisted >~/workspace/marker && mkdir -p ~/.claude && echo "{}" >~/.claude.json'
docker rm -f "${TEST_ID}" >/dev/null
start_container "${TEST_ID}-2" "${TEST_ID}-home"
wait_healthy "${TEST_ID}-2"
[[ $(in_ssh "${TEST_ID}-2" 'ssh-keygen -lf ~/.ssh/host/ssh_host_ed25519_key.pub') == "${fingerprint}" ]] ||
	die "the host key changed across recreation"
[[ $(in_ssh "${TEST_ID}-2" 'cat ~/workspace/marker') == persisted ]] || die "the home volume did not persist"
in_ssh "${TEST_ID}-2" 'test -s ~/.claude.json && test -s ~/.config/herdr/config.toml' || die "configuration did not persist"
pass "recreation keeps the host key, home, workspace and configuration"

echo "smoke: all checks passed"
