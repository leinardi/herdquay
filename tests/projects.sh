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
# Runs the normal development workflows of the owner's projects inside a running HerdQuay
# container, as its unprivileged user, to prove the image's toolchains cover them. Manual: it needs
# the local checkouts next to this repository and network access (pre-commit hook environments,
# make-common, Go modules, npm packages).
#
# Usage: tests/projects.sh [<project>...]   (default: all five)
#
# Each checkout is copied into the container's workspace volume (no host mount), without
# node_modules or caches, then its commands run in a login shell. Targets that need a Docker
# daemon, privileges, hardware or release credentials are not run: docs/dev-environment.md lists
# them and why.

set -euo pipefail

CONTAINER="${HERDQUAY_CONTAINER:-herdquay-herdquay-1}"
WORKSPACE_ROOT="$(cd "$(git rev-parse --show-toplevel)/.." && pwd)"

declare -A COMMANDS=(
	[swarm-device-access]="make verify-go && make check"
	[monmux]="make check && make go-lint-cross && goreleaser check && goreleaser release --snapshot --clean --skip=publish,sign"
	[awtrix-controller]="make verify && make check"
	[bitgauge]="make web-install && make web-build && make verify && npx --prefix web playwright install chromium firefox webkit && make e2e"
	[runhold]="make web-install && make web-build && make verify-go verify-web"
)

run_project() {
	local project="$1" target log
	target="/home/herdquay/workspace/${project}"
	[[ -d ${WORKSPACE_ROOT}/${project} ]] || {
		echo "skip ${project}: no checkout at ${WORKSPACE_ROOT}/${project}"
		return 0
	}
	echo "=== ${project}: copying"
	docker exec "${CONTAINER}" rm -rf "${target}"
	docker exec "${CONTAINER}" mkdir -p "${target}"
	tar -C "${WORKSPACE_ROOT}/${project}" \
		--exclude=node_modules --exclude=.cache --exclude=dist --exclude=coverage.out -cf - . |
		docker exec -i "${CONTAINER}" tar -C "${target}" -xf -
	log="$(mktemp "/tmp/herdquay-${project}.XXXXXX.log")"
	echo "=== ${project}: ${COMMANDS[${project}]}  (log: ${log})"
	if docker exec -w "${target}" "${CONTAINER}" bash -lc "${COMMANDS[${project}]}" >"${log}" 2>&1; then
		echo "=== ${project}: PASS"
	else
		echo "=== ${project}: FAIL (last lines of ${log}):"
		tail -n 25 "${log}"
		return 1
	fi
}

failed=0
projects=("$@")
((${#projects[@]})) || projects=(swarm-device-access monmux awtrix-controller bitgauge runhold)
for project in "${projects[@]}"; do
	[[ -n ${COMMANDS[${project}]:-} ]] || {
		echo "unknown project: ${project}" >&2
		exit 2
	}
	run_project "${project}" || failed=1
done
exit "${failed}"
