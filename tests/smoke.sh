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
# the doctor's Docker check against stub daemons (tests/docker-stub.py),
# the commit identity, agent forwarding, secret permissions, and persistence of the host key and
# home across container recreation, and GPG commit signing (only for the custom identity, renewed
# keys picked up). Needs no real credentials.
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
		-v "${REPO_ROOT}/tests/docker-stub.py:${STUB_DIR}/docker-stub.py:ro" \
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

SIGNING_KEY_MOUNT="${HERDQUAY_SECRETS_DIR}/git_signing_key:/run/secrets/git_signing_key:ro"

# commit <name> [git command...]: an empty commit in a new repository, then the command (default:
# print the raw commit object).
commit() {
	local name="$1"
	shift
	in_ssh "${name}" "cd \"\$(mktemp -d)\" && git init -q && git commit -q --allow-empty -m probe && ${*:-git cat-file commit HEAD}"
}

# wait_rust <name>: herdquay-rust-install runs in the background once sshd and Herdr are up, and
# the first start's download can outlast the healthcheck; waits for its result in the log.
wait_rust() {
	wait_log "$1" "Rust .* installed (the image's minimum is\\|warning: Rust is not installed" 600
}

make_secrets
start_with_stub "${TEST_ID}" "${TEST_ID}-home" -v "${SIGNING_KEY_MOUNT}"
wait_healthy "${TEST_ID}"
pass "container healthy"
wait_rust "${TEST_ID}"

[[ $(in_ssh "${TEST_ID}" 'id -u'):$(in_ssh "${TEST_ID}" 'id -g') == 568:568 ]] || die "SSH session is not 568:568"
pass "SSH login as 568:568"

in_ssh "${TEST_ID}" 'herdquay doctor' >"${SCRATCH}/doctor.txt" || {
	cat "${SCRATCH}/doctor.txt" >&2
	die "herdquay doctor failed"
}
pass "herdquay doctor: $(tail -n 1 "${SCRATCH}/doctor.txt")"

# docker_doctor <DOCKER_HOST>: the doctor's Docker line with that daemon configured.
docker_doctor() {
	in_ssh "${TEST_ID}" "DOCKER_HOST=$1 herdquay doctor || true" | sed -n '/^Docker$/{n;p;q}'
}

grep -q '^  ok    no Docker daemon configured' "${SCRATCH}/doctor.txt" ||
	die "herdquay doctor does not report that no Docker daemon is configured"
docker exec -d "${TEST_ID}" python3 "${STUB_DIR}/docker-stub.py" 18082 rootless
docker exec -d "${TEST_ID}" python3 "${STUB_DIR}/docker-stub.py" 18083 rootful
in_ssh "${TEST_ID}" "for i in \$(seq 100); do
	curl -fs http://127.0.0.1:18082/_ping >/dev/null && curl -fs http://127.0.0.1:18083/_ping >/dev/null && exit 0
	sleep 0.1
done; exit 1" || die "the stub Docker APIs did not start"
grep -q '^  ok    dedicated rootless Docker daemon at tcp://127.0.0.1:18082 ' <<<"$(docker_doctor tcp://127.0.0.1:18082)" ||
	die "herdquay doctor does not accept a rootless daemon"
grep -q '^  FAIL  the Docker daemon at tcp://127.0.0.1:18083 is not rootless' <<<"$(docker_doctor tcp://127.0.0.1:18083)" ||
	die "herdquay doctor accepts a daemon that is not rootless"
grep -q '^  FAIL  the Docker daemon at tcp://127.0.0.1:1 is unreachable' <<<"$(docker_doctor tcp://127.0.0.1:1)" ||
	die "herdquay doctor does not fail on an unreachable daemon"
grep -q '^  FAIL  /var/run/docker.sock exists' <<<"$(docker run --rm --entrypoint herdquay \
	-v /dev/null:/var/run/docker.sock "${IMAGE}" doctor 2>&1 || true)" ||
	die "herdquay doctor does not fail on /var/run/docker.sock"
pass "doctor Docker check: none by default, rootless accepted, rootful, unreachable and the socket fail"

# session_env <name> <in_ssh|in_login|in_tty>: the Docker variables a session of that kind sees,
# one `HQ <name><<value>>` line each; DOCKER_CONFIG, not on the list, is never forwarded.
# shellcheck disable=SC2016 # expanded by the session's shell
SESSION_ENV_PROBE='for n in DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_CONFIG; do printf "HQ %s<%s>\n" "$n" "$(printenv "$n")"; done'
session_env() {
	"$2" "$1" "${SESSION_ENV_PROBE}" | grep '^HQ DOCKER_'
}

# assert_session_env <name> <expected lines>: the same view from `ssh host cmd`, a login shell and
# an interactive login shell on a PTY.
assert_session_env() {
	local kind
	[[ $(in_tty "$1" 'echo "HQI<$->"' | grep '^HQI<') == HQI\<*i* ]] ||
		die "$1: the PTY session is not an interactive shell"
	for kind in in_ssh in_login in_tty; do
		[[ $(session_env "$1" "${kind}") == "$2" ]] ||
			die "$1: ${kind} sees $(session_env "$1" "${kind}"), not $2"
	done
}

NO_SESSION_ENV='HQ DOCKER_HOST<>
HQ DOCKER_TLS_VERIFY<>
HQ DOCKER_CERT_PATH<>
HQ DOCKER_CONFIG<>'
assert_session_env "${TEST_ID}" "${NO_SESSION_ENV}"
in_ssh "${TEST_ID}" 'test ! -e ~/.ssh/environment' || die ".ssh/environment exists without a Docker variable"
pass "no Docker variable on the container: none in SSH sessions"

# Swarm ignores no-new-privileges, so nothing in the image may raise privileges in its place.
privileged="$(docker run --rm --entrypoint bash "${IMAGE}" -c \
	'find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null; getcap -r / 2>/dev/null')"
[[ -z ${privileged} ]] || die "setuid, setgid or file-capability binaries in the image: ${privileged}"
pass "no setuid, setgid or file-capability binary in the image"

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
[[ $(in_ssh "${TEST_ID}" 'stat -c %a /dev/shm/herdquay-github; stat -c %a /dev/shm/herdquay-github/* | sort -u') == $'700\n600' ]] ||
	die "the token cache is not a 0700 directory of 0600 files in /dev/shm"
in_ssh "${TEST_ID}" "! grep -rqsF '${token}' ~/.config ~/.local/state ~/.cache ~/.gitconfig" ||
	die "a token reached the home volume"
pass "git HTTPS: per-repository App token, cached in /dev/shm (0600), one mint"

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

# Captured first: a failed commit stops the test here instead of reading as unsigned.
out="$(commit "${TEST_ID}")"
grep -q '^tree ' <<<"${out}" || die "no commit was made: ${out}"
grep -q '^gpgsig' <<<"${out}" && die "a commit by the App bot was signed"
[[ -z $(in_ssh "${TEST_ID}" 'git config commit.gpgsign; git config tag.gpgsign' || true) ]] ||
	die "gpgsign is configured for the App bot"
grep -q '^  warn  commit signing off: .* is ignored, the identity is the GitHub App' <<<"$(in_ssh "${TEST_ID}" 'herdquay doctor')" ||
	die "herdquay doctor does not warn about a signing key ignored for the App bot"
pass "signing key with the App bot: ignored, commits unsigned, doctor warns"

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

grep -q github_ssh_key <<<"$(in_ssh "${TEST_ID}" 'ssh -G github.com')" && die "ssh still uses the old GitHub key for github.com"
in_ssh "${TEST_ID}" 'test ! -e /etc/ssh/ssh_config.d/herdquay.conf && test ! -e /etc/ssh/ssh_known_hosts' ||
	die "the GitHub SSH client configuration is still shipped"
in_ssh "${TEST_ID}" "git config --system --get-regexp '^credential\\.https://gist\\.github\\.com'" &&
	die "a gist.github.com credential helper is configured"
pass "no GitHub SSH key, config or host keys; no Gist credential helper"

eval "$(ssh-agent -s)" >/dev/null
ssh-add -q "${CLIENT_KEY}"
grep -q herdquay-test-client <<<"$(in_ssh "${TEST_ID}" 'ssh-add -l' -A)" || die "agent forwarding does not work"
pass "agent forwarding for manual SSH sessions"

for secret in authorized_keys github_app_key git_signing_key; do
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

out="$(commit "${TEST_ID}-2")"
grep -q '^tree ' <<<"${out}" || die "no commit was made: ${out}"
grep -q '^gpgsig' <<<"${out}" && die "a commit was signed without a signing key"
grep -q '^  ok    commit signing off (no signing key' <<<"$(in_ssh "${TEST_ID}-2" 'herdquay doctor')" ||
	die "herdquay doctor does not report signing off"
pass "no signing key: commits unsigned, doctor reports signing off"

pinned="$(docker exec "${TEST_ID}-2" sed -n 's/^HERDQUAY_CLAUDE_VERSION=//p' /usr/local/share/herdquay/claude-release)"
[[ $(in_ssh "${TEST_ID}-2" 'readlink -f ~/.local/bin/claude') == "/home/herdquay/.local/share/claude/versions/${pinned}" ]] ||
	die "the claude link is not the pinned ${pinned}"
grep -qF "${pinned}" <<<"$(in_ssh "${TEST_ID}-2" 'claude --version')" || die "claude --version is not ${pinned}"
grep -q "Claude Code ${pinned} installed (the image's minimum is ${pinned})" <<<"$(docker logs "${TEST_ID}-2" 2>&1)" ||
	die "the recreated container downloaded Claude Code again"
docker run --rm --entrypoint bash "${IMAGE}" -c 'test ! -e /usr/local/bin/claude && ! command -v claude' >/dev/null ||
	die "the image itself ships a claude binary"
if docker run --rm --entrypoint herdquay-claude-install \
	-e HERDQUAY_CLAUDE_SIGNER_FINGERPRINT=0000000000000000000000000000000000000000 "${IMAGE}" >/dev/null 2>&1; then
	die "herdquay-claude-install accepted a manifest signed by an unexpected key"
fi
pass "Claude Code ${pinned}: installed at first start, verified, kept across recreation, not in the image"

opencode_version="$(docker exec "${TEST_ID}-2" /usr/local/share/herdquay/opencode --version)"
[[ $(in_ssh "${TEST_ID}-2" 'command -v opencode') == /home/herdquay/.opencode/bin/opencode ]] ||
	die "opencode does not run from ~/.opencode/bin"
[[ $(in_ssh "${TEST_ID}-2" 'opencode --version') == "${opencode_version}" ]] || die "opencode is not the image's ${opencode_version}"
docker run --rm --entrypoint bash "${IMAGE}" -c '! command -v opencode' >/dev/null ||
	die "the image puts its own opencode on the PATH"
pass "${opencode_version}: copied into ~/.opencode/bin, the only one on the PATH"

wait_rust "${TEST_ID}-2"
rust_minimum="$(docker exec "${TEST_ID}-2" sed -n 's/^HERDQUAY_RUST_MINIMUM=//p' /usr/local/share/herdquay/rust-release)"
[[ $(in_ssh "${TEST_ID}-2" 'command -v cargo') == /home/herdquay/.cargo/bin/cargo ]] ||
	die "cargo does not run from ~/.cargo/bin"
grep -q "^  ok    Rust .*, at or above the image's ${rust_minimum}" <<<"$(in_ssh "${TEST_ID}-2" 'herdquay doctor' || true)" ||
	die "herdquay doctor does not report Rust at or above ${rust_minimum}"
grep -q "Rust .* installed (the image's minimum is ${rust_minimum})" <<<"$(docker logs "${TEST_ID}-2" 2>&1)" ||
	die "the start log does not report Rust at or above ${rust_minimum}"
if in_ssh "${TEST_ID}-2" 'HERDQUAY_RUST_MINIMUM=999.0.0 herdquay-rust-install' >/dev/null 2>&1; then
	die "herdquay-rust-install accepted a toolchain below its minimum"
fi
# A checkout pinning a toolchain that is not installed: both check the default, not the override.
pinned_checkout='mkdir -p /tmp/pinned && cd /tmp/pinned && printf "[toolchain]\nchannel = \"1.0.0\"\n" >rust-toolchain.toml'
grep -q "^  ok    Rust .*, at or above the image's ${rust_minimum}" <<<"$(in_ssh "${TEST_ID}-2" "${pinned_checkout} && herdquay doctor" || true)" ||
	die "herdquay doctor checks a rust-toolchain.toml override, not the default toolchain"
in_ssh "${TEST_ID}-2" "${pinned_checkout} && RUSTUP_AUTO_INSTALL=0 herdquay-rust-install" >/dev/null 2>&1 ||
	die "herdquay-rust-install checks a rust-toolchain.toml override, not the default toolchain"
# Without a working rustup, the doctor reports it and still runs to its summary.
out="$(in_ssh "${TEST_ID}-2" 'RUSTUP_HOME=/nonexistent herdquay doctor' || true)"
grep -q '^  FAIL  Rust: no default toolchain' <<<"${out}" ||
	die "herdquay doctor does not report a missing Rust toolchain"
grep -q '^[0-9]* failure(s), [0-9]* warning(s)$' <<<"${out}" ||
	die "herdquay doctor stops at a missing Rust toolchain"
docker run --rm --entrypoint bash "${IMAGE}" -c '! command -v rustc && ! command -v cargo && ! command -v rustup' >/dev/null ||
	die "the image itself puts Rust on the PATH"
pass "Rust: rustup and stable in the home volume at or above ${rust_minimum}, not in the image"

# fake_versions <name> <version>: a stand-in Claude Code <version>, linked as Anthropic's updater
# links one, and a stand-in opencode <version> in ~/.opencode/bin, as `opencode upgrade` leaves it.
fake_versions() {
	in_ssh "$1" "v=~/.local/share/claude/versions
printf '#!/bin/sh\necho \"$2 (Claude Code)\"\n' >\$v/$2 && chmod 0755 \$v/$2 && ln -sfn \$v/$2 ~/.local/bin/claude
printf '#!/bin/sh\necho opencode v$2\n' >~/.opencode/bin/opencode.new && chmod 0755 ~/.opencode/bin/opencode.new &&
mv -f ~/.opencode/bin/opencode.new ~/.opencode/bin/opencode"
}

# A self-update survives a restart; a version below the image's is replaced, and Claude Code's
# older versions are removed.
fake_versions "${TEST_ID}-2" 99.0.0
docker restart "${TEST_ID}-2" >/dev/null
wait_healthy "${TEST_ID}-2"
[[ $(in_ssh "${TEST_ID}-2" 'readlink -f ~/.local/bin/claude') == /home/herdquay/.local/share/claude/versions/99.0.0 ]] ||
	die "a restart reverted a newer Claude Code"
[[ $(in_ssh "${TEST_ID}-2" 'opencode --version') == "opencode v99.0.0" ]] || die "a restart reverted a newer opencode"
in_ssh "${TEST_ID}-2" "test -x ~/.local/share/claude/versions/${pinned}" || die "the restart removed Claude Code ${pinned}"
grep -q '^  ok    Claude Code 99.0.0, at or above' <<<"$(in_ssh "${TEST_ID}-2" 'herdquay doctor' || true)" ||
	die "herdquay doctor does not accept a newer Claude Code"
fake_versions "${TEST_ID}-2" 0.0.1
docker restart "${TEST_ID}-2" >/dev/null
wait_healthy "${TEST_ID}-2"
[[ $(in_ssh "${TEST_ID}-2" 'readlink -f ~/.local/bin/claude') == "/home/herdquay/.local/share/claude/versions/${pinned}" ]] ||
	die "an older Claude Code was not replaced with ${pinned}"
in_ssh "${TEST_ID}-2" 'test ! -e ~/.local/share/claude/versions/0.0.1 && test -x ~/.local/share/claude/versions/99.0.0' ||
	die "the versions below ${pinned} were not removed, or a newer one was"
[[ $(in_ssh "${TEST_ID}-2" 'opencode --version') == "${opencode_version}" ]] ||
	die "an older opencode was not replaced with the image's"
in_ssh "${TEST_ID}-2" 'rm ~/.local/share/claude/versions/99.0.0'
pass "self-updates: newer Claude Code and opencode kept across restarts, older ones replaced"

# A home from an older HerdQuay, whose entrypoint seeded user.* into ~/.gitconfig: it keeps that
# identity, the file is left alone, and the doctor says how to clean it up.
in_ssh "${TEST_ID}-2" 'git config --global user.name "Old Seeded" && git config --global user.email old@example.invalid'
gitconfig="$(in_ssh "${TEST_ID}-2" 'sha256sum ~/.gitconfig')"
docker rm -f "${TEST_ID}-2" >/dev/null
start_with_stub "${TEST_ID}-3" "${TEST_ID}-home" \
	-e HERDQUAY_GIT_NAME="HerdQuay Test" -e HERDQUAY_GIT_EMAIL=test@example.invalid
wait_healthy "${TEST_ID}-3"
wait_rust "${TEST_ID}-3"
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

in_ssh "${TEST_ID}-3" 'git config --global --unset user.name && git config --global --unset user.email'
docker rm -f "${TEST_ID}-3" >/dev/null
start_with_stub "${TEST_ID}-4" "${TEST_ID}-home" -v "${SIGNING_KEY_MOUNT}" \
	-e HERDQUAY_GIT_NAME="HerdQuay Test" -e HERDQUAY_GIT_EMAIL=test@example.invalid
wait_healthy "${TEST_ID}-4"
wait_rust "${TEST_ID}-4"
grep -q '^gpgsig' <<<"$(commit "${TEST_ID}-4")" || die "a commit with the signing key is not signed"
grep -qF "${SIGNING_UID}" <<<"$(commit "${TEST_ID}-4" 'git verify-commit HEAD 2>&1')" || die "git verify-commit failed"
in_ssh "${TEST_ID}-4" 'test ! -e ~/.gnupg' || die "a .gnupg directory was created on the home volume"
in_ssh "${TEST_ID}-4" 'herdquay doctor' >"${SCRATCH}/doctor.txt" || {
	cat "${SCRATCH}/doctor.txt" >&2
	die "herdquay doctor failed with the signing key"
}
if ! grep -q "^  ok    commit signing on: ${SIGNING_FINGERPRINT}, expires " "${SCRATCH}/doctor.txt" ||
	! grep -q "^  ok    test signature with ${SIGNING_FINGERPRINT}" "${SCRATCH}/doctor.txt" ||
	grep -q 'no UID of the signing key matches' "${SCRATCH}/doctor.txt"; then
	die "herdquay doctor does not report signing on: $(grep -i sign "${SCRATCH}/doctor.txt")"
fi
pass "signing key with HERDQUAY_GIT_NAME/EMAIL: commits signed and verified, no ~/.gnupg, doctor ok"

# Renewal: the same key with a later expiry, written over the secret in place (as a rotated secret
# file appears); the primary fingerprint does not change, the key data does.
GNUPGHOME="${SIGNING_GNUPG}" gpg --batch --quiet --quick-set-expire "${SIGNING_FINGERPRINT}" 2y 2>/dev/null
expiry="$(GNUPGHOME="${SIGNING_GNUPG}" gpg --batch --with-colons --list-keys "${SIGNING_FINGERPRINT}" 2>/dev/null |
	awk -F: '$1 == "pub" { print $7; exit }')"
GNUPGHOME="${SIGNING_GNUPG}" gpg --batch --armor --export-secret-keys >"${HERDQUAY_SECRETS_DIR}/git_signing_key"
commit "${TEST_ID}-4" 'git verify-commit HEAD' 2>/dev/null || die "the commit after renewal does not verify"
[[ $(in_ssh "${TEST_ID}-4" "herdquay-gpg --batch --with-colons --list-keys ${SIGNING_FINGERPRINT}" |
	awk -F: '$1 == "pub" { print $7; exit }') == "${expiry}" ]] || die "herdquay-gpg did not pick up the renewed key"
pass "renewed signing key (same fingerprint, new expiry) used for the next commit"

# The Docker variables the deployment sets reach every kind of SSH session verbatim (sshd reads
# ~/.ssh/environment, no shell does), and only the allow-listed ones. The crafted value is no
# endpoint the doctor can reach: only its mismatch lines are checked here.
# shellcheck disable=SC2016 # the $(...) and backticks are the payload, never expanded
EVIL_HOST='tcp://127.0.0.1:1;$(touch /tmp/pwned) `touch /tmp/pwned` "q"'
CERT_PATH='/run/secrets/docker tls'
HERDQUAY_CLAUDE_INSTALL=0 HERDQUAY_RUST_INSTALL=0 start_container "${TEST_ID}-env" "${TEST_ID}-env-home" \
	-e DOCKER_HOST="${EVIL_HOST}" -e DOCKER_TLS_VERIFY=1 -e DOCKER_CERT_PATH="${CERT_PATH}" -e DOCKER_CONFIG=/tmp/cfg
wait_healthy "${TEST_ID}-env"
expected="HQ DOCKER_HOST<${EVIL_HOST}>
HQ DOCKER_TLS_VERIFY<1>
HQ DOCKER_CERT_PATH<${CERT_PATH}>
HQ DOCKER_CONFIG<>"
assert_session_env "${TEST_ID}-env" "${expected}"
docker exec "${TEST_ID}-env" test ! -e /tmp/pwned || die "a Docker variable's value was run by a shell"
[[ $(docker exec "${TEST_ID}-env" bash -c 'tr "\0" "\n" <"/proc/$(pgrep -xo herdr)/environ"' |
	grep -E '^DOCKER_(HOST|TLS_VERIFY|CERT_PATH)=' | sort) == "$(printf '%s\n' "DOCKER_CERT_PATH=${CERT_PATH}" \
	"DOCKER_HOST=${EVIL_HOST}" DOCKER_TLS_VERIFY=1)" ]] || die "the Herdr server does not have the container's Docker variables"
in_ssh "${TEST_ID}-env" 'herdquay doctor || true' | grep -q ' differs from the container' &&
	die "herdquay doctor reports a mismatch where the session matches the container"
grep -q '^  warn  DOCKER_HOST differs from the container.s: session tcp://other, container ' \
	<<<"$(in_ssh "${TEST_ID}-env" 'DOCKER_HOST=tcp://other herdquay doctor || true')" ||
	die "herdquay doctor does not report a session DOCKER_HOST that differs from the container's"
pass "Docker variables on the container: verbatim in every SSH session and Herdr, the rest not; doctor compares"

# sshd takes only the allow-listed names from the file, even when it is edited by hand.
in_ssh "${TEST_ID}-env" 'printf "FOO=bar\nPATH=/evil\n" >>~/.ssh/environment'
# shellcheck disable=SC2016 # expanded by the session's shell
[[ $(in_ssh "${TEST_ID}-env" 'printf "%s|%s" "${FOO:-unset}" "${PATH}"') == unset\|/home/herdquay/.local/bin:* ]] ||
	die "sshd took a name off the allow-list from ~/.ssh/environment"
pass ".ssh/environment: names off the allow-list ignored"

# Unset on the container is unset in sessions again, although the home volume persists.
docker rm -f "${TEST_ID}-env" >/dev/null
HERDQUAY_CLAUDE_INSTALL=0 HERDQUAY_RUST_INSTALL=0 start_container "${TEST_ID}-env2" "${TEST_ID}-env-home"
wait_healthy "${TEST_ID}-env2"
assert_session_env "${TEST_ID}-env2" "${NO_SESSION_ENV}"
in_ssh "${TEST_ID}-env2" 'test ! -e ~/.ssh/environment' || die ".ssh/environment survived the variables' removal"
docker rm -f "${TEST_ID}-env2" >/dev/null

# A line break would end the value's line in ~/.ssh/environment: the variable is dropped instead.
HERDQUAY_CLAUDE_INSTALL=0 HERDQUAY_RUST_INSTALL=0 start_container "${TEST_ID}-env3" "${TEST_ID}-env-home" \
	-e "DOCKER_HOST=tcp://127.0.0.1:1"$'\n'"DOCKER_CONFIG=/tmp/cfg"
wait_healthy "${TEST_ID}-env3"
wait_log "${TEST_ID}-env3" 'warning: DOCKER_HOST contains a line break' 5
assert_session_env "${TEST_ID}-env3" "${NO_SESSION_ENV}"
docker rm -f "${TEST_ID}-env3" >/dev/null
pass "removed or line-broken Docker variables: unset in SSH sessions"

echo "smoke: all checks passed"
