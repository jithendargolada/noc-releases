#!/usr/bin/env bash
#
# Rebuild the APT repo metadata under agent/packaging/linux/repos/apt/.
# Drops any number of .deb files into pool/main/a/nethraops-agent/
# first, then run this script.
#
# Layout:
#   apt/
#     pool/main/a/nethraops-agent/   .deb files (any version)
#     dists/stable/main/binary-amd64/      Packages, Packages.gz, Release
#
# This script does NOT sign the Release file. Production signing is a
# Phase 1D job; see ../README.md.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB_DIST="$(cd "${HERE}/../../deb/dist" 2>/dev/null && pwd)" || DEB_DIST=""

POOL="${HERE}/pool/main/a/nethraops-agent"
DIST_DIR="${HERE}/dists/stable/main/binary-amd64"
mkdir -p "${POOL}" "${DIST_DIR}"

# Pull in the freshest .deb the local build produced (if any) so a
# bare `bash build-repo.sh` after a `bash deb/build.sh` produces a
# usable repo without any further dance.
if [ -n "${DEB_DIST}" ] && compgen -G "${DEB_DIST}/*.deb" > /dev/null; then
    cp -f "${DEB_DIST}"/*.deb "${POOL}/"
fi

if ! compgen -G "${POOL}/*.deb" > /dev/null; then
    echo "ERROR: no .deb files under ${POOL}/" >&2
    echo "Build one with: bash agent/packaging/linux/deb/build.sh" >&2
    exit 1
fi

if ! command -v apt-ftparchive >/dev/null 2>&1; then
    echo "ERROR: apt-ftparchive not found. Install the `apt-utils` package." >&2
    exit 127
fi

echo "==> generating Packages"
( cd "${HERE}" && apt-ftparchive packages pool > "${DIST_DIR}/Packages" )

echo "==> generating Packages.gz"
gzip -kf9 "${DIST_DIR}/Packages"

echo "==> generating Release"
cat > "${HERE}/apt-ftparchive.conf" <<'CONF'
APT::FTPArchive::Release {
    Origin "NethraOps";
    Label "NethraOps";
    Suite "stable";
    Codename "stable";
    Architectures "amd64";
    Components "main";
    Description "NethraOps agent APT repository";
};
CONF

( cd "${HERE}/dists/stable" && \
    apt-ftparchive -c "${HERE}/apt-ftparchive.conf" release . > Release )

echo "==> apt repo refreshed under ${HERE}"
echo
echo "To sign (Phase 1D, requires a GPG key):"
echo "  gpg --default-key <KEYID> -abs -o ${HERE}/dists/stable/Release.gpg ${HERE}/dists/stable/Release"
echo "  gpg --default-key <KEYID> --clearsign -o ${HERE}/dists/stable/InRelease ${HERE}/dists/stable/Release"
