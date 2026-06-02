#!/usr/bin/env bash
#
# Build nethraops-agent-<version>-1.noarch.rpm.
#
# Requirements: rpmbuild (from the `rpm-build` package on Rocky / RHEL
# / Fedora; not generally available on Debian/Ubuntu without the
# `rpm` package). This script will FAIL with a clear message if
# rpmbuild is not on PATH - DO NOT try to install it from inside the
# script. Run this on a Rocky / RHEL build host or in a container
# (e.g. `docker run --rm -v $PWD:/work rockylinux:9 bash /work/...`).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../../.." && pwd)"
AGENT_SRC="${REPO_ROOT}/agent"

if ! command -v rpmbuild >/dev/null 2>&1; then
    cat >&2 <<'NOTFOUND'
ERROR: rpmbuild not found on PATH.

Install rpm-build (Rocky / RHEL / Fedora):
    sudo dnf install -y rpm-build systemd-rpm-macros

Or run on a Rocky 9 container from a Debian/Ubuntu/WSL build host:
    docker run --rm -v $PWD:/work -w /work rockylinux:9 bash -c '
        dnf install -y rpm-build systemd-rpm-macros python3 tar gzip
        bash agent/packaging/linux/rpm/build.sh
    '

The .spec at agent/packaging/linux/rpm/nethraops-agent.spec is
fully ready - this script just cannot exercise it here.
NOTFOUND
    exit 127
fi

VERSION="$(awk -F\" '/^version *= */{print $2; exit}' "${AGENT_SRC}/pyproject.toml")"
NAME=nethraops-agent

TOPDIR="$(mktemp -d -t nethraops-rpm-build.XXXXXX)"
trap 'rm -rf "${TOPDIR}"' EXIT

mkdir -p "${TOPDIR}/BUILD" "${TOPDIR}/RPMS" "${TOPDIR}/SOURCES" "${TOPDIR}/SPECS" "${TOPDIR}/SRPMS"

# Build a source tarball with the layout the .spec expects:
#   <name>-<version>/
#     pyproject.toml
#     README.md
#     src/
#     packaging/linux/deb/...     (so %install can grab the unit + helper)
STAGE="$(mktemp -d -t nethraops-rpm-stage.XXXXXX)"
trap 'rm -rf "${TOPDIR}" "${STAGE}"' EXIT
mkdir -p "${STAGE}/${NAME}-${VERSION}"
cp -r "${AGENT_SRC}/pyproject.toml" "${AGENT_SRC}/README.md" "${AGENT_SRC}/src" \
      "${STAGE}/${NAME}-${VERSION}/"
mkdir -p "${STAGE}/${NAME}-${VERSION}/packaging/linux"
cp -r "${HERE}/../deb" "${STAGE}/${NAME}-${VERSION}/packaging/linux/deb"

( cd "${STAGE}" && tar czf "${TOPDIR}/SOURCES/${NAME}-${VERSION}.tar.gz" "${NAME}-${VERSION}" )

cp "${HERE}/nethraops-agent.spec" "${TOPDIR}/SPECS/"

echo "==> running rpmbuild"
rpmbuild --define "_topdir ${TOPDIR}" -bb "${TOPDIR}/SPECS/nethraops-agent.spec"

OUT_DIR="${HERE}/dist"
mkdir -p "${OUT_DIR}"
find "${TOPDIR}/RPMS" -name "*.rpm" -exec cp {} "${OUT_DIR}/" \;

# Optional signing (Phase 1D). If GPG_KEY_ID is exported (and rpm-sign
# is installed) sign each produced .rpm via the shared signing wrapper.
SIGN_KEY="${GPG_KEY_ID:-${NETHRAOPS_REPO_KEY_ID:-}}"
SIGNING_SCRIPT="${HERE}/../../signing/sign-rpm.sh"
if [ -n "${SIGN_KEY}" ] && [ -x "${SIGNING_SCRIPT}" ]; then
    echo "==> signing produced RPMs with key ${SIGN_KEY}"
    bash "${SIGNING_SCRIPT}" -k "${SIGN_KEY}" "${OUT_DIR}"/*.rpm
fi

for f in "${OUT_DIR}"/*.rpm; do
    SHA=$(sha256sum "${f}" | awk '{print $1}')
    echo "${SHA}  $(basename "${f}")" > "${f}.sha256"
    echo "==> Built ${f} (SHA-256 ${SHA})"
done

echo "${VERSION}" > "${OUT_DIR}/VERSION"

# Signing (Phase 1D): requires a GPG key + ~/.rpmmacros with
# %_signature gpg / %_gpg_name <KEYID>.
#   rpm --addsign ${OUT_DIR}/*.rpm
#   gpg --detach-sign --armor agent/packaging/linux/repos/yum/repodata/repomd.xml
