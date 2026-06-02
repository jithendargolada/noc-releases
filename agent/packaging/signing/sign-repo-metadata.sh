#!/usr/bin/env bash
#
# Produce the APT + YUM repository metadata signatures (Phase 1D).
#
# APT consumes two artifacts per `dists/<suite>/`:
#   - Release.gpg : detached, ASCII-armored signature of Release
#   - InRelease   : Release contents wrapped in a `gpg --clearsign`
#                   envelope (preferred since apt 1.1; saves a roundtrip)
#
# YUM consumes one:
#   - repomd.xml.asc : detached, ASCII-armored signature of repomd.xml
#
# Usage:
#   bash sign-repo-metadata.sh [-k KEYID] <repos-root>
#
# <repos-root> is the directory containing apt/ and yum/ subdirectories
# (i.e. agent/packaging/linux/repos/ or the staged _site/ dir).

set -euo pipefail

KEY_ID=""

while getopts "k:" opt; do
    case "${opt}" in
        k) KEY_ID="${OPTARG}" ;;
        *) echo "Usage: $0 [-k KEYID] <repos-root>" >&2; exit 2 ;;
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

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 [-k KEYID] <repos-root>" >&2
    exit 2
fi
ROOT="$1"
if [ ! -d "${ROOT}" ]; then
    echo "ERROR: ${ROOT} not a directory." >&2
    exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
    echo "ERROR: gpg not found on PATH." >&2
    exit 127
fi

GPG_OPTS=(--batch --yes --pinentry-mode loopback --default-key "${KEY_ID}")
if [ -n "${GPG_PASSPHRASE:-}" ]; then
    GPG_OPTS+=(--passphrase "${GPG_PASSPHRASE}")
fi

signed_any=0

# ----- APT -----
shopt -s nullglob
for release in "${ROOT}/apt/dists"/*/Release; do
    dir="$(dirname "${release}")"
    echo "==> signing ${release}"
    gpg "${GPG_OPTS[@]}" --armor --detach-sign --output "${dir}/Release.gpg" "${release}"
    echo "==> clearsigning -> ${dir}/InRelease"
    gpg "${GPG_OPTS[@]}" --clearsign --output "${dir}/InRelease" "${release}"
    signed_any=1
done

# ----- YUM -----
if [ -f "${ROOT}/yum/repodata/repomd.xml" ]; then
    echo "==> signing ${ROOT}/yum/repodata/repomd.xml"
    gpg "${GPG_OPTS[@]}" --armor --detach-sign \
        --output "${ROOT}/yum/repodata/repomd.xml.asc" \
        "${ROOT}/yum/repodata/repomd.xml"
    signed_any=1
fi

if [ "${signed_any}" -eq 0 ]; then
    echo "WARN: no repo metadata found under ${ROOT}. Did you run" >&2
    echo "      apt/build-repo.sh + yum/build-repo.sh first?" >&2
    exit 1
fi

echo "==> done. Verify with:"
echo "      gpg --verify ${ROOT}/apt/dists/stable/Release.gpg \\"
echo "                   ${ROOT}/apt/dists/stable/Release"
echo "      gpg --verify ${ROOT}/yum/repodata/repomd.xml.asc \\"
echo "                   ${ROOT}/yum/repodata/repomd.xml"
