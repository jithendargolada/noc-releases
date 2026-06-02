#!/usr/bin/env bash
#
# Uninstall the NethraOps agent. Run as root.
#
# Removes:
#   - systemd unit at /etc/systemd/system/nethraops-agent.service
#   - virtualenv at /opt/nethraops-agent
#
# Preserves (unless --purge):
#   - /etc/nethraops-agent (config + secrets)
#   - /var/lib/nethraops-agent (buffer + state)
#   - the nethraops-agent system user

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root (sudo $0)" >&2
  exit 1
fi

PURGE=0
if [[ "${1:-}" == "--purge" ]]; then
  PURGE=1
fi

SERVICE_NAME="nethraops-agent.service"

echo "==> stopping ${SERVICE_NAME}"
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

echo "==> removing systemd unit"
rm -f "/etc/systemd/system/${SERVICE_NAME}"
systemctl daemon-reload

echo "==> removing virtualenv"
rm -rf /opt/nethraops-agent

if [[ "${PURGE}" == "1" ]]; then
  echo "==> --purge: removing config + state"
  rm -rf /etc/nethraops-agent
  rm -rf /var/lib/nethraops-agent
  if id -u nethraops-agent >/dev/null 2>&1; then
    userdel nethraops-agent || true
  fi
fi

echo "==> done."
