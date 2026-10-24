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
# GitHub App credentials against a stub API (tests/github-stub.py, on the container's loopback),
# the commit identity, agent forwarding, secret permissions, and persistence of the host key and
# home across container recreation. Needs no real credentials.
#
# Usage: tests/smoke.sh   (HERDQUAY_IMAGE selects the image, default herdquay:local)

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

STUB_DIR=/opt/herdquay-test
# Two stub APIs, started before the entrypoint so that its App bot lookup reaches the first one.
# The first also accepts a second App ID, for the cache isolation checks.
STUB_LAUNCH="python3 ${STUB_DIR}/github-stub.py 18080 ${STUB_DIR}/app.pub.pem ${APP_ID},67890 &
python3 ${STUB_DIR}/github-stub.py 18081 ${STUB_DIR}/app.pub.pem ${APP_ID} &
for i in \$(seq 100); do
	curl -fs http://127.0.0.1:18080/_stub/mints >/dev/null && curl -fs http://127.0.0.1:18081/_stub/mints >/dev/null && break
	sleep 0.1
done
exec /usr/local/bin/herdquay-entrypoint"

# start_with_stub <name> <home-volume> [docker run options...]
start_with_stub() {
	local name="$1" volume="$2"
	shift 2
	start_container "${name}" "${volume}" --entrypoint /usr/bin/tini \
		-v "${REPO_ROOT}/tests/github-stub.py:${STUB_DIR}/github-stub.py:ro" \
		-v "${APP_PUBLIC_KEY}:${STUB_DIR}/app.pub.pem:ro" \
		"$@" -- -- bash -c "${STUB_LAUNCH}"
}

# fill <name> <path>: Git's credential fill for https://github.com/<path>, as Git asks for it.
fill() {
	printf 'protocol=https\nhost=github.com\npath=%s\n\n' "$2" | in_ssh "$1" 'GIT_TERMINAL_PROMPT=0 git credential fill'
}

password() {
	fill "$1" "$2" | sed -n 's/^password=//p'
}

# mints <name> [port]: the tokens the stub has minted, as JSON.
mints() {
	in_ssh "$1" "curl -fsS http://127.0.0.1:${2:-18080}/_stub/mints"
}

mint_count() {
	mints "$@" | jq length
}

make_secrets
start_with_stub "${TEST_ID}" "${TEST_ID}-home"
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

out="$(fill "${TEST_ID}" o/r.git)"
grep -qx 'username=x-access-token' <<<"${out}" || die "git credential fill: no x-access-token username"
token="$(sed -n 's/^password=//p' <<<"${out}")"
[[ ${token} == "$(mints "${TEST_ID}" | jq -r '.[0].token')" ]] || die "git credential fill did not return the stub's token"
[[ $(mints "${TEST_ID}" | jq -c '.[0].repositories') == '["r"]' ]] || die "the token was not restricted to the repository r"
[[ $(password "${TEST_ID}" o/r.git) == "${token}" && $(mint_count "${TEST_ID}") == 1 ]] ||
	die "the second credential fill was not served from the cache"
[[ $(in_ssh "${TEST_ID}" 'stat -c %a /tmp/herdquay-github; stat -c %a /tmp/herdquay-github/* | sort -u') == $'700\n600' ]] ||
	die "the token cache is not a 0700 directory of 0600 files"
in_ssh "${TEST_ID}" "! grep -rqsF '${token}' ~/.config ~/.local/state ~/.cache ~/.gitconfig" ||
	die "a token reached the home volume"
pass "git HTTPS: per-repository App token, cached on tmpfs (0600), one mint"

all="$(in_ssh "${TEST_ID}" 'gh auth token')"
[[ ${all} == "$(mints "${TEST_ID}" | jq -r '.[-1].token')" && $(mints "${TEST_ID}" | jq -c '.[-1].repositories') == null ]] ||
	die "gh does not use an installation-wide App token"
in_ssh "${TEST_ID}" 'test ! -e ~/.config/gh/hosts.yml' || die "gh wrote hosts.yml"
pass "gh: installation-wide App token, nothing stored"

[[ $(in_ssh "${TEST_ID}" 'git ls-remote --get-url git@github.com:o/r.git') == https://github.com/o/r.git &&
	$(in_ssh "${TEST_ID}" 'git ls-remote --get-url ssh://git@github.com/o/r.git') == https://github.com/o/r.git ]] ||
	die "SSH GitHub URLs are not rewritten to HTTPS"
pass "SSH GitHub URLs rewritten to HTTPS"

[[ $(in_ssh "${TEST_ID}" 'git config user.name') == 'herdquay-test[bot]' &&
	$(in_ssh "${TEST_ID}" 'git config user.email') == '4242+herdquay-test[bot]@users.noreply.github.com' ]] ||
	die "the commit identity is not the App bot: $(in_ssh "${TEST_ID}" 'git var GIT_AUTHOR_IDENT')"
pass "commit identity: the App bot without HERDQUAY_GIT_NAME/EMAIL"

count="$(mint_count "${TEST_ID}")"
in_ssh "${TEST_ID}" 'cp ~/.config/herdquay/github.env /tmp/github.env.orig &&
	sed -i "s/^HERDQUAY_GITHUB_APP_ID=.*/HERDQUAY_GITHUB_APP_ID=67890/" ~/.config/herdquay/github.env'
[[ $(password "${TEST_ID}" o/r.git) != "${token}" && $(mint_count "${TEST_ID}") == $((count + 1)) ]] ||
	die "a changed App ID reused the old App's token"
in_ssh "${TEST_ID}" 'cp /tmp/github.env.orig ~/.config/herdquay/github.env &&
	sed -i "s|^HERDQUAY_GITHUB_API_URL=.*|HERDQUAY_GITHUB_API_URL=http://127.0.0.1:18081|" ~/.config/herdquay/github.env'
[[ $(password "${TEST_ID}" o/r.git) == ghs_18081_* ]] || die "a changed API URL reused the old API's token"
in_ssh "${TEST_ID}" 'cp /tmp/github.env.orig ~/.config/herdquay/github.env'
[[ $(password "${TEST_ID}" o/r.git) == "${token}" ]] || die "the original token is no longer cached"
count="$(mint_count "${TEST_ID}")"
printf 'protocol=https\nhost=github.com\npath=o/r.git\nusername=x-access-token\npassword=%s\n\n' "${token}" |
	in_ssh "${TEST_ID}" 'git credential reject'
[[ $(password "${TEST_ID}" o/r.git) != "${token}" && $(mint_count "${TEST_ID}") == $((count + 1)) ]] ||
	die "git credential reject did not drop the cached token"
pass "token cache: keyed by App ID and API URL, erased on reject"

count="$(mint_count "${TEST_ID}")"
in_ssh "${TEST_ID}" 'curl -fsS -d 240 http://127.0.0.1:18080/_stub/expires-in' >/dev/null
password "${TEST_ID}" o/w.git >/dev/null
password "${TEST_ID}" o/w.git >/dev/null
[[ $(mint_count "${TEST_ID}") == $((count + 2)) ]] || die "a token 4 minutes from expiry was reused"
in_ssh "${TEST_ID}" 'curl -fsS -d 3600 http://127.0.0.1:18080/_stub/expires-in' >/dev/null
password "${TEST_ID}" o/z.git >/dev/null
password "${TEST_ID}" o/z.git >/dev/null
[[ $(mint_count "${TEST_ID}") == $((count + 3)) ]] || die "a token an hour from expiry was not reused"
pass "token refresh: minted again inside the 5-minute window, reused outside it"

if out="$(fill "${TEST_ID}" o/missing.git 2>&1)" || ! grep -q 'not installed on o/missing' <<<"${out}"; then
	die "a repository without the App did not fail clearly: ${out}"
fi
pass "a repository without the App fails clearly"

in_ssh "${TEST_ID}" 'ssh -G github.com' | grep -q github_ssh_key && die "ssh still uses the old GitHub key for github.com"
in_ssh "${TEST_ID}" 'test ! -e /etc/ssh/ssh_config.d/herdquay.conf && test ! -e /etc/ssh/ssh_known_hosts' ||
	die "the GitHub SSH client configuration is still shipped"
in_ssh "${TEST_ID}" "git config --system --get-regexp '^credential\\.https://gist\\.github\\.com'" &&
	die "a gist.github.com credential helper is configured"
pass "no GitHub SSH key, config or host keys; no Gist credential helper"

eval "$(ssh-agent -s)" >/dev/null
ssh-add -q "${CLIENT_KEY}"
in_ssh "${TEST_ID}" 'ssh-add -l' -A | grep -q herdquay-test-client || die "agent forwarding does not work"
pass "agent forwarding for manual SSH sessions"

for secret in authorized_keys github_app_key; do
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
start_with_stub "${TEST_ID}-2" "${TEST_ID}-home" \
	-e HERDQUAY_GIT_NAME="HerdQuay Test" -e HERDQUAY_GIT_EMAIL=test@example.invalid
wait_healthy "${TEST_ID}-2"
[[ $(in_ssh "${TEST_ID}-2" 'ssh-keygen -lf ~/.ssh/host/ssh_host_ed25519_key.pub') == "${fingerprint}" ]] ||
	die "the host key changed across recreation"
[[ $(in_ssh "${TEST_ID}-2" 'cat ~/workspace/marker') == persisted ]] || die "the home volume did not persist"
in_ssh "${TEST_ID}-2" 'test -s ~/.claude.json && test -s ~/.config/herdr/config.toml' || die "configuration did not persist"
pass "recreation keeps the host key, home, workspace and configuration"

[[ $(in_ssh "${TEST_ID}-2" 'git var GIT_AUTHOR_IDENT' | sed 's/> .*/>/') == 'HerdQuay Test <test@example.invalid>' ]] ||
	die "HERDQUAY_GIT_NAME/EMAIL are not the commit identity"
pass "commit identity: HERDQUAY_GIT_NAME and HERDQUAY_GIT_EMAIL"

pinned="$(docker exec "${TEST_ID}-2" sed -n 's/^HERDQUAY_CLAUDE_VERSION=//p' /usr/local/share/herdquay/claude-release)"
[[ $(in_ssh "${TEST_ID}-2" 'readlink -f ~/.local/bin/claude') == "/home/herdquay/.local/share/claude/versions/${pinned}" ]] ||
	die "the claude link is not the pinned ${pinned}"
in_ssh "${TEST_ID}-2" 'claude --version' | grep -qF "${pinned}" || die "claude --version is not ${pinned}"
docker logs "${TEST_ID}-2" 2>&1 | grep -q "Claude Code ${pinned} already installed" ||
	die "the recreated container downloaded Claude Code again"
docker run --rm --entrypoint bash "${IMAGE}" -c 'test ! -e /usr/local/bin/claude && ! command -v claude' >/dev/null ||
	die "the image itself ships a claude binary"
if docker run --rm --entrypoint herdquay-claude-install \
	-e HERDQUAY_CLAUDE_SIGNER_FINGERPRINT=0000000000000000000000000000000000000000 "${IMAGE}" >/dev/null 2>&1; then
	die "herdquay-claude-install accepted a manifest signed by an unexpected key"
fi
pass "Claude Code ${pinned}: installed at first start, verified, kept across recreation, not in the image"

# A home from an older HerdQuay, whose entrypoint seeded user.* into ~/.gitconfig: it keeps that
# identity, the file is left alone, and the doctor says how to clean it up.
in_ssh "${TEST_ID}-2" 'git config --global user.name "Old Seeded" && git config --global user.email old@example.invalid'
gitconfig="$(in_ssh "${TEST_ID}-2" 'sha256sum ~/.gitconfig')"
docker rm -f "${TEST_ID}-2" >/dev/null
start_with_stub "${TEST_ID}-3" "${TEST_ID}-home" \
	-e HERDQUAY_GIT_NAME="HerdQuay Test" -e HERDQUAY_GIT_EMAIL=test@example.invalid
wait_healthy "${TEST_ID}-3"
[[ $(in_ssh "${TEST_ID}-3" 'git var GIT_AUTHOR_IDENT' | sed 's/> .*/>/') == 'Old Seeded <old@example.invalid>' ]] ||
	die "the seeded ~/.gitconfig identity did not stay effective"
[[ $(in_ssh "${TEST_ID}-3" 'sha256sum ~/.gitconfig') == "${gitconfig}" ]] || die "the home's .gitconfig was changed"
in_ssh "${TEST_ID}-3" 'herdquay doctor' >"${SCRATCH}/doctor.txt" || {
	cat "${SCRATCH}/doctor.txt" >&2
	die "herdquay doctor failed"
}
grep -q '^  warn  .*gitconfig.*git config --global --unset user.name' "${SCRATCH}/doctor.txt" ||
	die "herdquay doctor does not warn about the seeded ~/.gitconfig identity"
pass "an older home keeps its seeded identity, untouched; the doctor warns with the cleanup"

echo "smoke: all checks passed"
