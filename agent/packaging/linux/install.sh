#!/usr/bin/env bash
#
# Install the NethraOps agent on a systemd Linux host.
#
# Run as root. Idempotent — safe to re-run for upgrades.
#
# What it does:
#   1. Creates the `nethraops-agent` system user + service group.
#   2. Sets up /opt/nethraops-agent/venv with the agent + deps.
#   3. Creates /etc/nethraops-agent/agent.env (template, 0640 root:nethraops-agent).
#   4. Creates /var/lib/nethraops-agent for the buffer + state.
#   5. Installs and enables the systemd unit.
#
# Customise via env vars before running:
#   NETHRAOPS_BACKEND_URL=https://monitor.acme.com  ./install.sh
#   NETHRAOPS_ENROLMENT_TOKEN=...                   ./install.sh
#   NETHRAOPS_DEVICE_SLUG=db-east-01                ./install.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root (sudo $0)" >&2
  exit 1
fi

APP_DIR="${APP_DIR:-/opt/nethraops-agent}"
VENV_DIR="${VENV_DIR:-${APP_DIR}/venv}"
ETC_DIR="${ETC_DIR:-/etc/nethraops-agent}"
DATA_DIR="${DATA_DIR:-/var/lib/nethraops-agent}"
USER_NAME="${USER_NAME:-nethraops-agent}"
SERVICE_NAME="nethraops-agent.service"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"  # /agent

# 1. User
if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
  echo "==> creating system user ${USER_NAME}"
  useradd --system --no-create-home --home-dir "${DATA_DIR}" --shell /usr/sbin/nologin "${USER_NAME}"
fi

# 2. Directories
echo "==> creating directories"
install -d -m 0755 "${APP_DIR}"
install -d -m 0750 -o "${USER_NAME}" -g "${USER_NAME}" "${DATA_DIR}"
install -d -m 0750 -o root -g "${USER_NAME}" "${ETC_DIR}"

# 3. Virtualenv
echo "==> setting up Python virtualenv at ${VENV_DIR}"
PYTHON="${PYTHON:-python3}"
if [[ ! -d "${VENV_DIR}" ]]; then
  ${PYTHON} -m venv "${VENV_DIR}"
fi
"${VENV_DIR}/bin/pip" install --upgrade pip wheel >/dev/null
"${VENV_DIR}/bin/pip" install "${SOURCE_DIR}"

# 4. Config template
ENV_FILE="${ETC_DIR}/agent.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "==> creating ${ENV_FILE} (template)"
  cat > "${ENV_FILE}" <<EOF
# NethraOps agent configuration.
# Edit this file then \`systemctl restart ${SERVICE_NAME%.service}\`.

NETHRAOPS_BACKEND_URL=${NETHRAOPS_BACKEND_URL:-https://monitor.example.com}

# One-shot enrolment token (issued by the platform admin) OR a long-lived
# agent_token. The agent self-registers on first start when only an
# enrolment token is set.
NETHRAOPS_ENROLMENT_TOKEN=${NETHRAOPS_ENROLMENT_TOKEN:-}
NETHRAOPS_AGENT_TOKEN=${NETHRAOPS_AGENT_TOKEN:-}

NETHRAOPS_DEVICE_SLUG=${NETHRAOPS_DEVICE_SLUG:-$(hostname -s | tr '[:upper:]' '[:lower:]')}
NETHRAOPS_DEVICE_NAME=${NETHRAOPS_DEVICE_NAME:-$(hostname -s)}
NETHRAOPS_DEVICE_TYPE=linux

NETHRAOPS_COLLECT_INTERVAL_SECONDS=15
NETHRAOPS_FLUSH_INTERVAL_SECONDS=15
NETHRAOPS_FLUSH_BATCH_SIZE=200
NETHRAOPS_MAX_BUFFER_FRAMES=10000

NETHRAOPS_LOG_LEVEL=INFO
NETHRAOPS_LOG_FORMAT=json
EOF
  chown root:"${USER_NAME}" "${ENV_FILE}"
  chmod 0640 "${ENV_FILE}"
fi

# 5. systemd unit
echo "==> installing ${SERVICE_NAME}"
install -m 0644 "${SCRIPT_DIR}/${SERVICE_NAME}" "/etc/systemd/system/${SERVICE_NAME}"
systemctl daemon-reload

if [[ "${ENABLE_SERVICE:-1}" == "1" ]]; then
  echo "==> enabling + starting ${SERVICE_NAME}"
  systemctl enable "${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"
fi

cat <<EOF

==> NethraOps agent installed.

  Status:    systemctl status ${SERVICE_NAME%.service}
  Logs:      journalctl -u ${SERVICE_NAME%.service} -f
  Config:    ${ENV_FILE}
  Buffer:    ${DATA_DIR}/buffer.sqlite
  State:     ${DATA_DIR}/state.json

If you used an enrolment token, the agent has self-registered and the
long-lived token has been written to ${DATA_DIR}/state.json. You can
now revoke the enrolment token in the NethraOps console.

EOF
