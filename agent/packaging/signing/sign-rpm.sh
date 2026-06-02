#!/usr/bin/env bash
#
# Sign one or more .rpm packages with `rpm --addsign` (Phase 1D).
#
# Unlike debsigs the rpm signature is checked by default by `dnf` / `yum`
# when `gpgcheck=1` is set on the repo - so this is the primary signing
# path for the RPM channel.
#
# `rpm --addsign` calls gpg under the hood and needs to know the key id
# via ~/.rpmmacros. We materialise a minimal .rpmmacros on the fly so
# the operator does not have to maintain one by hand. The macro file is
# placed under $HOME unless RPMMACROS is exported (CI does this so
# concurrent jobs do not stomp each other).
#
# Usage:
#   bash sign-rpm.sh [-k KEYID] <foo.rpm> [<bar.rpm> ...]

set -euo pipefail

KEY_ID=""

while getopts "k:" opt; do
    case "${opt}" in
        k) KEY_ID="${OPTARG}" ;;
        *) echo "Usage: $0 [-k KEYID] <rpm> [...]" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

if [ -z "${KEY_ID}" ]; then
    KEY_ID="${GPG_KEY_ID:-${NETHRAOPS_REPO_KEY_ID:-}}"
fi
if [ -z "${KEY_ID}" ]; then
    echo "ERROR: no GPG key id. Pass -k KEYID or set GPG_KEY_ID." >&2
    exit 1
fi

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 [-k KEYID] <rpm> [...]" >&2
    exit 2
fi

if ! command -v rpm >/dev/null 2>&1; then
    cat >&2 <<'NOTFOUND'
ERROR: rpm not found on PATH.

Install on Rocky / RHEL / Fedora:    sudo dnf install -y rpm-sign
Install on Debian / Ubuntu:          sudo apt install -y rpm rpm-sign
NOTFOUND
    exit 127
fi
if ! command -v gpg >/dev/null 2>&1; then
    echo "ERROR: gpg not found on PATH." >&2
    exit 127
fi

RPMMACROS_FILE="${RPMMACROS:-${HOME}/.rpmmacros}"

# Preserve any existing .rpmmacros so we don't trash a developer's setup.
TMP_BACKUP=""
if [ -f "${RPMMACROS_FILE}" ]; then
    TMP_BACKUP="$(mktemp -t rpmmacros.bak.XXXXXX)"
    cp -f "${RPMMACROS_FILE}" "${TMP_BACKUP}"
fi
trap '[ -n "${TMP_BACKUP}" ] && mv -f "${TMP_BACKUP}" "${RPMMACROS_FILE}"' EXIT

cat > "${RPMMACROS_FILE}" <<EOF
%_signature gpg
%_gpg_name  ${KEY_ID}
%__gpg /usr/bin/gpg
%_gpg_path ${GNUPGHOME:-${HOME}/.gnupg}
EOF

for rpm_file in "$@"; do
    if [ ! -f "${rpm_file}" ]; then
        echo "ERROR: ${rpm_file} not found." >&2
        exit 1
    fi
    echo "==> signing ${rpm_file} with key ${KEY_ID}"
    rpm --addsign "${rpm_file}"
    echo "    OK. Verify with:  rpm --checksig ${rpm_file}"
done
