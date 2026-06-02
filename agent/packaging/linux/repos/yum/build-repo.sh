#!/usr/bin/env bash
#
# Rebuild the YUM/DNF repo metadata under
# agent/packaging/linux/repos/yum/. Drop .rpm files into noarch/ first
# (the rpm build script does this automatically when run).
#
# Layout:
#   yum/
#     noarch/                  *.rpm files
#     repodata/                repomd.xml + sqlite/xml indexes
#
# This script requires createrepo_c (the modern fast C reimplementation
# of the older Python `createrepo` tool). Most distros package it under
# the same name; Debian/Ubuntu also has it as `createrepo-c`.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_DIST="$(cd "${HERE}/../../rpm/dist" 2>/dev/null && pwd)" || RPM_DIST=""

NOARCH="${HERE}/noarch"
mkdir -p "${NOARCH}" "${HERE}/repodata"

if [ -n "${RPM_DIST}" ] && compgen -G "${RPM_DIST}/*.rpm" > /dev/null; then
    cp -f "${RPM_DIST}"/*.rpm "${NOARCH}/"
fi

if ! command -v createrepo_c >/dev/null 2>&1 && ! command -v createrepo >/dev/null 2>&1; then
    cat >&2 <<'NOTFOUND'
WARN: createrepo_c not installed. Leaving an empty repodata/ skeleton.

Install (Debian/Ubuntu):  sudo apt install createrepo-c
Install (Rocky/RHEL):     sudo dnf install createrepo_c

After installing, re-run this script - it is idempotent and will
materialise the full repomd.xml + primary.xml.gz indexes.
NOTFOUND
    # Drop a stub repomd.xml so the directory is not empty and the
    # backend / operator tooling has something to inspect.
    cat > "${HERE}/repodata/repomd.xml" <<'STUB'
<?xml version="1.0" encoding="UTF-8"?>
<!-- repomd.xml stub. Run agent/packaging/linux/repos/yum/build-repo.sh
     on a host with createrepo_c installed to materialise the real
     metadata indexes. -->
<repomd xmlns="http://linux.duke.edu/metadata/repo"/>
STUB
    exit 0
fi

CREATEREPO=$(command -v createrepo_c || command -v createrepo)
echo "==> running ${CREATEREPO}"
"${CREATEREPO}" --update "${HERE}"

echo "==> yum repo refreshed under ${HERE}"
echo
echo "To sign (Phase 1D, requires a GPG key):"
echo "  gpg --default-key <KEYID> --detach-sign --armor ${HERE}/repodata/repomd.xml"
echo "  rpm --addsign ${NOARCH}/*.rpm"
