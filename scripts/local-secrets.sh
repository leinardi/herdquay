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
# Provisions the local Compose harness's secrets in local/secrets/ (ignored by Git and by the
# build context) so the container's unprivileged user, UID 568, can read them and nobody else on
# this machine can. HERDQUAY_SECRETS_DIR overrides the directory (the tests use a scratch one).
#
# Non-Swarm Compose bind-mounts a file-backed secret with its host owner and mode, ignoring the
# secret's uid, gid and mode, so a 0600 file you own is unreadable by 568. Instead of loosening the
# mode, each file stays yours, 0600, and a POSIX ACL grants read to UID 568 alone. The named-user
# entry turns the group mode bits into the ACL mask, so ls and stat show 0640 even though the
# owning group gets nothing: the check below reads the effective ACL instead of the mode bits.
#
# Usage: scripts/local-secrets.sh [--authorized-keys <file>] [--github-app-key <pem>]
#                                 [--git-signing-key <file>] [--check]
#   --authorized-keys  the public key(s) allowed to SSH in (default: the first of
#                      ~/.ssh/id_ed25519.pub, id_ecdsa.pub, id_rsa.pub)
#   --github-app-key   the GitHub App's private key, as downloaded from the App's settings
#                      (optional)
#   --git-signing-key  an armored GPG secret key without a passphrase, to sign commits and tags as
#                      HERDQUAY_GIT_NAME / HERDQUAY_GIT_EMAIL (optional)
#   --check            only verify the existing files
#
# The GitHub App key is optional: compose.github.yaml mounts it with HERDQUAY_GITHUB_APP_ID, and
# make compose-up adds that file only when local/secrets/github_app_key exists. The signing key is
# optional too: compose.github.yaml mounts it when local/secrets/git_signing_key exists, so only
# together with the App key.

set -euo pipefail

CONTAINER_UID="${HERDQUAY_UID:-568}"
SECRETS_DIR="${HERDQUAY_SECRETS_DIR:-$(git rev-parse --show-toplevel)/local/secrets}"
authorized_keys_source=""
github_app_key_source=""
git_signing_key_source=""
check_only=0

die() {
	echo "local-secrets: $*" >&2
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--authorized-keys)
		[[ $# -ge 2 ]] || die "--authorized-keys needs a file"
		authorized_keys_source="$2"
		shift 2
		;;
	--github-app-key)
		[[ $# -ge 2 ]] || die "--github-app-key needs a file"
		github_app_key_source="$2"
		shift 2
		;;
	--git-signing-key)
		[[ $# -ge 2 ]] || die "--git-signing-key needs a file"
		git_signing_key_source="$2"
		shift 2
		;;
	--check)
		check_only=1
		shift
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
done

if ! command -v setfacl >/dev/null || ! command -v getfacl >/dev/null; then
	die "setfacl/getfacl not found (Debian/Ubuntu: apt install acl)"
fi

# A secret GPG key that signs with an empty passphrase, checked in a throwaway keyring.
check_signing_key() {
	local file="$1" gnupg status=0
	command -v gpg >/dev/null || die "gpg not found, needed to check ${file}"
	gnupg="$(mktemp -d)"
	if ! GNUPGHOME="${gnupg}" gpg --batch --quiet --import "${file}" 2>/dev/null; then
		status=1
	elif ! GNUPGHOME="${gnupg}" gpg --batch --with-colons --list-secret-keys 2>/dev/null | grep -q '^sec:'; then
		status=2
	elif ! printf 'probe\n' | GNUPGHOME="${gnupg}" gpg --batch --pinentry-mode loopback --passphrase '' \
		--sign >/dev/null 2>&1; then
		status=3
	fi
	GNUPGHOME="${gnupg}" gpgconf --kill all 2>/dev/null || true
	rm -rf "${gnupg}"
	case "${status}" in
	1) die "${file} is not a GPG key" ;;
	2) die "${file} holds no secret key (export it with gpg --armor --export-secret-keys)" ;;
	3) die "${file} cannot sign without a passphrase (HerdQuay cannot unlock one)" ;;
	esac
}

# The effective ACL must be exactly: owner rw, UID 568 r, nothing for the group or anyone else.
check_file() {
	local file="$1" acl expected
	[[ -f ${file} && ! -L ${file} ]] || die "${file} is missing or not a regular file"
	[[ $(stat -c %u "${file}") == "$(id -u)" ]] || die "${file} is not owned by you"
	acl="$(getfacl -cpn "${file}" 2>/dev/null | sed '/^$/d; s/[[:space:]]*#effective:/ effective:/' | sort)"
	expected="$(printf '%s\n' "group::---" "mask::r--" "other::---" "user:${CONTAINER_UID}:r--" "user::rw-" | sort)"
	[[ ${acl} == "${expected}" ]] || die "$(printf '%s has the wrong ACL:\n%s\nexpected:\n%s' "${file}" "${acl}" "${expected}")"
}

provision_file() {
	local source="$1" target="$2"
	[[ -r ${source} ]] || die "cannot read ${source}"
	install -m 0600 "${source}" "${target}"
	setfacl -b "${target}"
	if ! setfacl -m "u:${CONTAINER_UID}:r" "${target}" 2>/dev/null; then
		die "$(printf '%s\n' "this filesystem does not support POSIX ACLs. Instead, give the file to the" \
			"container user (the mode stays 0400, nobody else gains access):" \
			"  sudo chown ${CONTAINER_UID}:${CONTAINER_UID} ${target} && sudo chmod 0400 ${target}")"
	fi
}

if ((!check_only)); then
	if [[ -z ${authorized_keys_source} ]]; then
		for candidate in id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
			if [[ -r ${HOME}/.ssh/${candidate} ]]; then
				authorized_keys_source="${HOME}/.ssh/${candidate}"
				break
			fi
		done
		[[ -n ${authorized_keys_source} ]] || die "no public key in ~/.ssh: pass --authorized-keys <file>"
	fi
	install -d -m 0700 "${SECRETS_DIR}"
	provision_file "${authorized_keys_source}" "${SECRETS_DIR}/authorized_keys"
	if [[ -n ${github_app_key_source} ]]; then
		# An empty passphrase: an encrypted key fails, since nothing could unlock it unattended.
		openssl pkey -noout -passin pass: -in "${github_app_key_source}" >/dev/null 2>&1 ||
			die "${github_app_key_source} is not an unencrypted private key (HerdQuay cannot unlock a passphrase)"
		provision_file "${github_app_key_source}" "${SECRETS_DIR}/github_app_key"
	fi
	if [[ -n ${git_signing_key_source} ]]; then
		check_signing_key "${git_signing_key_source}"
		provision_file "${git_signing_key_source}" "${SECRETS_DIR}/git_signing_key"
	fi
fi

[[ $(stat -c %a "${SECRETS_DIR}") == 700 ]] || die "${SECRETS_DIR} must be mode 0700"
for file in "${SECRETS_DIR}"/*; do
	check_file "${file}"
done
echo "local-secrets: $(find "${SECRETS_DIR}" -type f | wc -l) secret file(s) readable by you and UID ${CONTAINER_UID} only"
