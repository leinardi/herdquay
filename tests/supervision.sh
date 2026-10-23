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
# Supervision test of a built image: a child dying on its own stops the container with a non-zero
# status, a requested stop is bounded and clean, a child that ignores SIGTERM is killed after
# HERDQUAY_STOP_TIMEOUT, and Herdr's session survives the stop.
#
# Usage: tests/supervision.sh   (HERDQUAY_IMAGE selects the image, default herdquay:local)

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

export HERDQUAY_STOP_TIMEOUT=5
# Every case starts on a fresh home volume: the smoke test covers the Claude Code install.
export HERDQUAY_CLAUDE_INSTALL=0

# wait_exit <name> <seconds>: prints the exit code once the container has stopped.
wait_exit() {
	local name="$1" seconds="$2" i
	for ((i = 0; i < seconds * 5; i++)); do
		if [[ $(docker inspect -f '{{.State.Running}}' "${name}") == false ]]; then
			docker inspect -f '{{.State.ExitCode}}' "${name}"
			return 0
		fi
		sleep 0.2
	done
	die "${name} still running after ${seconds}s"
}

make_secrets

for child in sshd herdr; do
	name="${TEST_ID}-${child}"
	start_container "${name}" "${name}-home"
	wait_healthy "${name}"
	docker exec "${name}" pkill -x "${child}"
	code="$(wait_exit "${name}" 10)"
	[[ ${code} != 0 ]] || die "killing ${child} left exit code 0"
	docker logs "${name}" 2>&1 | grep -q "stopping sshd and the Herdr server" || die "no orderly shutdown after ${child} died"
	pass "${child} killed: container exited ${code}, the other child stopped"
done

name="${TEST_ID}-stop"
start_container "${name}" "${name}-home"
wait_healthy "${name}"
docker exec "${name}" herdr workspace create --cwd /home/herdquay/workspace --label probe --no-focus >/dev/null
before="$(date +%s)"
start=$SECONDS
docker stop -t 30 "${name}" >/dev/null
elapsed=$((SECONDS - start))
code="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
[[ ${code} == 0 ]] || die "docker stop: exit code ${code}"
((elapsed <= HERDQUAY_STOP_TIMEOUT + 3)) || die "docker stop took ${elapsed}s"
saved="$(docker run --rm -v "${name}-home:/home/herdquay" --entrypoint stat "${IMAGE}" -c %Y /home/herdquay/.config/herdr/session.json)"
((saved >= before)) || die "session.json was not written on the way out"
docker start "${name}" >/dev/null
wait_healthy "${name}"
docker exec "${name}" herdr workspace list | jq -e '.result.workspaces[] | select(.label == "probe")' >/dev/null ||
	die "the layout was not restored after the stop"
pass "docker stop: exit 0 in ${elapsed}s, session saved and restored"

# A frozen process cannot act on SIGTERM: the entrypoint must SIGKILL it after the timeout.
docker exec "${name}" pkill -STOP -x herdr
start=$SECONDS
docker stop -t 30 "${name}" >/dev/null
elapsed=$((SECONDS - start))
((elapsed >= HERDQUAY_STOP_TIMEOUT && elapsed <= HERDQUAY_STOP_TIMEOUT + 5)) ||
	die "stop with a frozen child took ${elapsed}s (expected about ${HERDQUAY_STOP_TIMEOUT}s)"
docker logs "${name}" 2>&1 | grep -q "ignored SIGTERM" || die "the frozen child was not reported"
pass "a child ignoring SIGTERM is killed after ${HERDQUAY_STOP_TIMEOUT}s (stop took ${elapsed}s)"

echo "supervision: all checks passed"
