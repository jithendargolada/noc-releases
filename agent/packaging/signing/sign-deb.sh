#!/usr/bin/env bash
#
# Sign a .deb with debsigs (Phase 1D).
#
# debsigs embeds a detached signature inside the .deb's ar archive as
# `_gpgorigin`. APT does NOT verify these by default - end users have
# to install `debsig-verify` and drop a policy under
# /etc/debsig/policies/<keyid>/. The more common pattern is to verify
# the REPOSITORY metadata signature (InRelease / Release.gpg) and trust
# the apt repo as a whole - that flow is owned by sign-repo-metadata.sh.
#
# We still ship the per-.deb signature because:
#   * `apt download` + `dpkg -i` users want a way to verify standalone
#     downloads from the public site.
#   * `debsigs --show <deb>` is a no-network sanity check the operator
#     can run from `agent/packaging/linux/deb/dist/` before publishing.
#
# Usage:
#   bash sign-deb.sh [-k KEYID] <path/to/foo.deb> [<path/to/bar.deb> ...]
#
# If -k is omitted, falls back to env vars GPG_KEY_ID then NETHRAOPS_REPO_KEY_ID.
# Exits 127 if `debsigs` is missing (with a clear "apt install debsigs"
# hint), exits 1 if no key id is available, exits 0 on success.

set -euo pipefail

KEY_ID=""

while getopts "k:" opt; do
    case "${opt}" in
        k) KEY_ID="${OPTARG}" ;;
        *) echo "Usage: $0 [-k KEYID] <deb> [...]" >&2; exit 2 ;;
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
    echo "Usage: $0 [-k KEYID] <deb> [...]" >&2
    exit 2
fi

if ! command -v debsigs >/dev/null 2>&1; then
    cat >&2 <<'NOTFOUND'
ERROR: debsigs not found on PATH.

Install on Debian / Ubuntu / WSL:
    sudo apt install -y debsigs

On other distros the package may be named `debsigs` or unavailable
upstream - check your package manager. The CI workflow at
.github/workflows/publish-packages.yml installs it explicitly.
NOTFOUND
    exit 127
fi

if ! command -v gpg >/dev/null 2>&1; then
    echo "ERROR: gpg not found on PATH." >&2
    exit 127
fi

for deb in "$@"; do
    if [ ! -f "${deb}" ]; then
        echo "ERROR: ${deb} not found." >&2
        exit 1
    fi
    echo "==> signing ${deb} with key ${KEY_ID}"
    debsigs --sign=origin --default-key="${KEY_ID}" "${deb}"
    echo "    OK. Verify with:  debsigs --show ${deb}"
done
