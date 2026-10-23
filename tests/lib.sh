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
# Shared helpers for the image tests: a scratch secrets directory, a throwaway SSH client key, and
# a container started the way the harness and the deployment run it (all capabilities dropped,
# no-new-privileges, /tmp as an exec tmpfs, secrets bind-mounted as files). Sourced, not run.

# shellcheck disable=SC2034 # the variables are for the scripts that source this file
REPO_ROOT="$(git rev-parse --show-toplevel)"
IMAGE="${HERDQUAY_IMAGE:-herdquay:local}"
TEST_ID="hq-test-$$"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/herdquay-test.XXXXXX")"
CLIENT_KEY="${SCRATCH}/client_ed25519"
KNOWN_HOSTS="${SCRATCH}/known_hosts"
export HERDQUAY_SECRETS_DIR="${SCRATCH}/secrets"

containers=()
volumes=()

cleanup() {
	local name
	for name in "${containers[@]}"; do docker rm -f "${name}" >/dev/null 2>&1 || true; done
	for name in "${volumes[@]}"; do docker volume rm -f "${name}" >/dev/null 2>&1 || true; done
	[[ -n ${SSH_AGENT_PID:-} ]] && kill "${SSH_AGENT_PID}" 2>/dev/null
	rm -rf "${SCRATCH}"
}
trap cleanup EXIT

pass() { printf '  ok    %s\n' "$*"; }
die() {
	printf '  FAIL  %s\n' "$*" >&2
	exit 1
}

# Real key files, provisioned with the same ACL script the harness uses.
make_secrets() {
	ssh-keygen -q -t ed25519 -N '' -C herdquay-test-client -f "${CLIENT_KEY}"
	ssh-keygen -q -t ed25519 -N '' -C herdquay-test-github -f "${SCRATCH}/github_ssh_key"
	printf 'github_pat_test_token\n' >"${SCRATCH}/github_token"
	"${REPO_ROOT}/scripts/local-secrets.sh" --authorized-keys "${CLIENT_KEY}.pub" \
		--github-ssh-key "${SCRATCH}/github_ssh_key" --github-token-file "${SCRATCH}/github_token" >/dev/null
	rm -f "${SCRATCH}/github_ssh_key" "${SCRATCH}/github_ssh_key.pub" "${SCRATCH}/github_token"
}

# start_container <name> <home-volume> [docker run options...]: prints nothing, records the name.
start_container() {
	local name="$1" volume="$2"
	shift 2
	containers+=("${name}")
	volumes+=("${volume}")
	docker run -d --name "${name}" \
		--cap-drop ALL --security-opt no-new-privileges:true \
		--tmpfs /tmp:rw,exec,nosuid,nodev,mode=1777 \
		-p 127.0.0.1::2222 \
		-v "${volume}:/home/herdquay" \
		-v "${HERDQUAY_SECRETS_DIR}/authorized_keys:/run/secrets/authorized_keys:ro" \
		-v "${HERDQUAY_SECRETS_DIR}/github_ssh_key:/run/secrets/github_ssh_key:ro" \
		-v "${HERDQUAY_SECRETS_DIR}/github_token:/run/secrets/github_token:ro" \
		-e HERDQUAY_STOP_TIMEOUT="${HERDQUAY_STOP_TIMEOUT:-5}" \
		"$@" "${IMAGE}" >/dev/null
}

wait_healthy() {
	local name="$1" i status
	for ((i = 0; i < 90; i++)); do
		status="$(docker inspect -f '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo gone)"
		[[ ${status} == healthy ]] && return 0
		[[ ${status} == gone ]] && break
		sleep 1
	done
	docker logs "${name}" 2>&1 | tail -n 20 >&2
	die "${name} did not become healthy (${status})"
}

ssh_port() {
	docker port "$1" 2222/tcp | head -n 1 | sed 's/.*://'
}

# in_ssh <name> <command> [ssh options...]: runs a command over SSH as the container's user.
in_ssh() {
	local name="$1" command="$2"
	shift 2
	ssh -T -i "${CLIENT_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR \
		-o UserKnownHostsFile="${KNOWN_HOSTS}" -o StrictHostKeyChecking=accept-new \
		-p "$(ssh_port "${name}")" "$@" herdquay@127.0.0.1 "${command}"
}
