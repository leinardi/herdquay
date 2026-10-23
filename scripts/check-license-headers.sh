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
# License header checker.
#
# Fails on any tracked code file whose first lines do not carry the herdquay MIT notice and
# copyright line, so a missing header is caught as surely as one copied from another project. YAML,
# JSON and Markdown are never governed: they are configuration and documentation, not code files in
# this sense.
#
# Exempt: the make-common files the bootstrap fetches (they carry make-common's own MIT header;
# read from the Makefile's MK_COMMON_FILES) and scripts/bootstrap-mk-common.sh, which comes from
# make-common too. Add generated and vendored files to the exemptions, each for a reason.

set -euo pipefail

# --- Configuration -------------------------------------------------------------------------------

# Named in the messages, and in a GPL notice's "This file is part of ..." line.
PROJECT_NAME="herdquay"

# The copyright holder, as the copyright line names it.
COPYRIGHT_HOLDER="Roberto Leinardi"

# The license, as the messages name it.
LICENSE_NAME="MIT"

# Lines the header must contain, verbatim.
REQUIRED_LINES=(
	"MIT License"
	"Permission is hereby granted, free of charge, to any person obtaining a copy"
	"THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR"
)

# The copyright line: the year (or years) and the holder, on one line. Matches both
# "Copyright (c) 2026 Name" (MIT, GPL) and "Copyright 2026 Name." (Apache-2.0). An extended regex,
# so a holder with regex metacharacters needs them escaped.
COPYRIGHT_REGEX="Copyright (\\(c\\) )?[0-9]{4}([-, ]+[0-9]{4})* ${COPYRIGHT_HOLDER}\\.?\$"

# How many leading lines the header must sit in: a shebang and a comment line may precede it.
HEADER_WINDOW=30

# Governed file extensions (without the dot), and governed file names matched on the base name.
# Repo-local .mk fragments are governed too; the make-common ones are exempt below.
GOVERNED_EXTENSIONS=(sh bash)
GOVERNED_NAMES=(Makefile Dockerfile "*.Dockerfile" "herdquay" "herdquay-*" "gh")

# Path prefixes and exact paths that are not this project's own code.
EXEMPT_PREFIXES=()
EXEMPT_PATHS=(
	"scripts/bootstrap-mk-common.sh"
)

# --- End of configuration ------------------------------------------------------------------------

usage() {
	cat <<'USAGE'
Usage: scripts/check-license-headers.sh

Checks every tracked code file for the license header configured at the top of this script and
lists the files that lack it. Run from anywhere inside the repository.
USAGE
}

if [[ $# -gt 0 ]]; then
	usage >&2
	exit 2
fi

if [[ ${#REQUIRED_LINES[@]} -eq 0 || -z ${LICENSE_NAME} ]]; then
	echo "The license-header check is not configured: set LICENSE_NAME and REQUIRED_LINES at the" >&2
	echo "top of scripts/check-license-headers.sh (AGENTS.md, \"License headers\")." >&2
	exit 2
fi

cd "$(git rev-parse --show-toplevel)"

# The shared make fragments, read from the Makefile so the list cannot drift from what the
# bootstrap actually fetches.
mk_common_files() {
	sed -n 's/^MK_COMMON_FILES[[:space:]]*:=[[:space:]]*//p' Makefile
}

is_governed() {
	local path="$1" base entry
	base="${path##*/}"

	if [[ ${path} == .mk/*.mk ]]; then
		return 0
	fi

	for entry in "${GOVERNED_EXTENSIONS[@]}"; do
		if [[ ${base} == *."${entry}" ]]; then
			return 0
		fi
	done

	for entry in "${GOVERNED_NAMES[@]}"; do
		# Unquoted on purpose: an entry may be a glob.
		# shellcheck disable=SC2053
		if [[ ${base} == ${entry} ]]; then
			return 0
		fi
	done

	return 1
}

is_exempt() {
	local path="$1" entry

	for entry in ${EXEMPT_PREFIXES[@]+"${EXEMPT_PREFIXES[@]}"}; do
		if [[ ${path} == "${entry}"* ]]; then
			return 0
		fi
	done

	for entry in ${EXEMPT_PATHS[@]+"${EXEMPT_PATHS[@]}"}; do
		if [[ ${path} == "${entry}" ]]; then
			return 0
		fi
	done

	for entry in ${COMMON_FILES}; do
		if [[ ${path} == ".mk/${entry}" ]]; then
			return 0
		fi
	done

	return 1
}

has_header() {
	local path="$1" head line
	head="$(head -n "${HEADER_WINDOW}" -- "${path}")"

	for line in "${REQUIRED_LINES[@]}"; do
		if [[ ${head} != *"${line}"* ]]; then
			return 1
		fi
	done

	grep -Eq -- "${COPYRIGHT_REGEX}" <<<"${head}"
}

COMMON_FILES="$(mk_common_files)"
if [[ -z ${COMMON_FILES} ]]; then
	echo "Could not read MK_COMMON_FILES from the Makefile." >&2
	exit 1
fi

missing=()
checked=0

while IFS= read -r -d '' path; do
	if ! is_governed "${path}" || is_exempt "${path}"; then
		continue
	fi

	# A tracked file deleted in the working tree is not this check's concern.
	if [[ ! -f ${path} ]]; then
		continue
	fi

	checked=$((checked + 1))

	if ! has_header "${path}"; then
		missing+=("${path}")
	fi
done < <(git ls-files -z)

if [[ ${checked} -eq 0 ]]; then
	echo "No governed files found: the check has nothing to check." >&2
	exit 1
fi

if [[ ${#missing[@]} -gt 0 ]]; then
	echo "These files lack the ${PROJECT_NAME} ${LICENSE_NAME} license header:" >&2
	printf '  %s\n' "${missing[@]}" >&2
	echo "Copy the header from a file that has it, with the year the file was first committed." >&2
	exit 1
fi

echo "License headers: ${checked} files checked, all carry the ${LICENSE_NAME} header."
