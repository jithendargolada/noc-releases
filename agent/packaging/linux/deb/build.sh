#!/usr/bin/env bash
#
# Build the nethraops-agent_<version>_all.deb.
#
# Requirements: dpkg-deb, fakeroot, md5sum, find. All ship in the
# `dpkg-dev` + `fakeroot` packages on Debian/Ubuntu/WSL.
#
# Output: agent/packaging/linux/deb/dist/nethraops-agent_<version>_all.deb
#         + <name>.sha256 sidecar.
#
# Signing (commented out): a release engineer runs `debsigs --sign=origin
# -k <KEYID> <pkg>.deb` AFTER this script, then `gpg --detach-sign
# --armor` to produce the InRelease/Release.gpg for the repo. The
# Phase 1C build environment has no GPG key, so signing is deferred
# to Phase 1D.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../../.." && pwd)"
AGENT_SRC="${REPO_ROOT}/agent"

VERSION="$(awk -F\" '/^version *= */{print $2; exit}' "${AGENT_SRC}/pyproject.toml")"
if [ -z "${VERSION}" ]; then
    echo "ERROR: failed to extract version from agent/pyproject.toml" >&2
    exit 1
fi

BUILD_ROOT="$(mktemp -d -t nethraops-deb-build.XXXXXX)"
trap 'rm -rf "${BUILD_ROOT}"' EXIT

OUT_DIR="${HERE}/dist"
mkdir -p "${OUT_DIR}"

PKG_NAME="nethraops-agent"
ARCH=all
OUT_FILE="${OUT_DIR}/${PKG_NAME}_${VERSION}_${ARCH}.deb"

echo "==> staging package tree under ${BUILD_ROOT}"

# 1. Stage DEBIAN/ control + maintainer scripts.
install -d -m 0755 "${BUILD_ROOT}/DEBIAN"
install -m 0644 "${HERE}/DEBIAN/control" "${BUILD_ROOT}/DEBIAN/control"
install -m 0644 "${HERE}/DEBIAN/conffiles" "${BUILD_ROOT}/DEBIAN/conffiles"
install -m 0755 "${HERE}/DEBIAN/postinst" "${BUILD_ROOT}/DEBIAN/postinst"
install -m 0755 "${HERE}/DEBIAN/prerm" "${BUILD_ROOT}/DEBIAN/prerm"
install -m 0755 "${HERE}/DEBIAN/postrm" "${BUILD_ROOT}/DEBIAN/postrm"

# Patch the Version field with whatever pyproject.toml says (single
# source of truth instead of hand-edited).
sed -i -E "s/^Version: .*/Version: ${VERSION}/" "${BUILD_ROOT}/DEBIAN/control"

# 2. Stage agent source tree at /usr/share/nethraops-agent/src/.
install -d -m 0755 "${BUILD_ROOT}/usr/share/nethraops-agent/src"
# Copy only what pip install needs (pyproject + src tree + README).
# Exclude build artefacts so the .deb stays small.
TAR_OPTS=(
    --exclude="__pycache__"
    --exclude="*.egg-info"
    --exclude=".pytest_cache"
    --exclude="dist"
    --exclude="build"
    --exclude="tests"
    --exclude="*.pyc"
)
( cd "${AGENT_SRC}" && tar cf - "${TAR_OPTS[@]}" pyproject.toml README.md src ) | \
    ( cd "${BUILD_ROOT}/usr/share/nethraops-agent/src" && tar xf - )

# 3. Stage systemd unit.
install -d -m 0755 "${BUILD_ROOT}/lib/systemd/system"
install -m 0644 "${HERE}/lib/systemd/system/nethraops-agent.service" \
    "${BUILD_ROOT}/lib/systemd/system/nethraops-agent.service"

# 4. Stage the enrol helper at /usr/bin/.
install -d -m 0755 "${BUILD_ROOT}/usr/bin"
install -m 0755 "${HERE}/usr/bin/nethraops-agent-enroll" "${BUILD_ROOT}/usr/bin/nethraops-agent-enroll"

# 5. Stage the install.conf example. The conffiles list references
#    /etc/nethraops-agent/install.conf.example specifically so dpkg
#    treats it as a config file (won't clobber operator edits on
#    upgrade). The real /etc/nethraops-agent/install.conf is created by
#    the operator, not shipped.
install -d -m 0750 "${BUILD_ROOT}/etc/nethraops-agent"
install -m 0644 "${HERE}/etc/nethraops-agent/install.conf.example" \
    "${BUILD_ROOT}/etc/nethraops-agent/install.conf.example"

# 6. md5sums (Debian policy 5.6.21).
echo "==> generating md5sums"
( cd "${BUILD_ROOT}" && \
    find usr lib etc -type f -exec md5sum {} \; | sort -k 2 \
    > "${BUILD_ROOT}/DEBIAN/md5sums" )
chmod 0644 "${BUILD_ROOT}/DEBIAN/md5sums"

# 7. Build with fakeroot so file ownerships land as root:root inside
#    the .ar archive even though we are not root on the build host.
echo "==> building ${OUT_FILE}"
if command -v fakeroot >/dev/null 2>&1; then
    fakeroot dpkg-deb --build --root-owner-group "${BUILD_ROOT}" "${OUT_FILE}"
else
    echo "WARN: fakeroot not installed; ownerships will be the build user." >&2
    dpkg-deb --build --root-owner-group "${BUILD_ROOT}" "${OUT_FILE}"
fi

# 8. Optional signing (Phase 1D). If GPG_KEY_ID (or NETHRAOPS_REPO_KEY_ID)
#    is set in the environment AND debsigs is installed, the build
#    automatically signs the .deb. Silent no-op otherwise so dev builds
#    on workstations without a key stay friction-free.
SIGN_KEY="${GPG_KEY_ID:-${NETHRAOPS_REPO_KEY_ID:-}}"
SIGNING_SCRIPT="${HERE}/../../signing/sign-deb.sh"
if [ -n "${SIGN_KEY}" ] && [ -x "${SIGNING_SCRIPT}" ]; then
    if command -v debsigs >/dev/null 2>&1; then
        echo "==> signing ${OUT_FILE} with key ${SIGN_KEY}"
        bash "${SIGNING_SCRIPT}" -k "${SIGN_KEY}" "${OUT_FILE}"
    else
        # Fallback: produce a detached .asc signature alongside the
        # .deb. apt does not consume this directly but `gpg --verify`
        # against the public key proves provenance for standalone
        # `dpkg -i` downloads from the hosted repo.
        echo "==> debsigs not installed; producing detached .asc only"
        gpg --batch --yes --pinentry-mode loopback --default-key "${SIGN_KEY}" \
            --armor --detach-sign --output "${OUT_FILE}.asc" "${OUT_FILE}"
    fi
fi

# 9. SHA-256 sidecar + console report.
SHA=$(sha256sum "${OUT_FILE}" | awk '{print $1}')
echo "${SHA}  $(basename "${OUT_FILE}")" > "${OUT_FILE}.sha256"

# 10. Drop a VERSION file alongside so the backend manifest endpoint
#    can advertise the latest version without parsing filenames.
echo "${VERSION}" > "${OUT_DIR}/VERSION"

SIZE=$(stat -c %s "${OUT_FILE}")
cat <<EOF

==> Build OK.
    Package:  ${OUT_FILE}
    Version:  ${VERSION}
    Size:     ${SIZE} bytes
    SHA-256:  ${SHA}

    Verify:   dpkg-deb --info ${OUT_FILE}
              dpkg-deb --contents ${OUT_FILE}

# To sign (Phase 1D, requires a GPG key on the build host):
#   debsigs --sign=origin -k <KEYID> ${OUT_FILE}
#   gpg --detach-sign --armor agent/packaging/linux/repos/apt/dists/stable/Release
EOF
