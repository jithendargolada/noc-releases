Name:           nethraops-agent
Version:        0.1.0
Release:        1%{?dist}
Summary:        NethraOps host telemetry agent

License:        Proprietary
URL:            https://github.com/jithendargolada/mysysteminfo
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

# Build-time only.
BuildRequires:  systemd-rpm-macros

# Runtime deps. We mirror the DEB Depends list.
Requires:       python3 >= 3.11
Requires:       python3-pip
Requires:       systemd
Requires:       curl
Requires:       ca-certificates

%{?systemd_requires}

%description
NethraOps agent collects host telemetry (CPU, memory, disk,
network, processes, containers, log tail) and pushes it to the
NethraOps platform on a 15 second cadence.

This package wraps the existing one-line install flow served at
/install/linux.sh, layering it under standard RPM lifecycle management
(dnf install / dnf upgrade / dnf remove, systemctl preset).

The per-host CLAIM_TOKEN is supplied at install time via
/etc/nethraops-agent/install.conf (KEY=VALUE) - nothing tenant-specific
is baked into the package.

%prep
%setup -q

%build
# Pure-Python agent; no compile step. The venv is created at install
# time (in %post) so the runtime uses the host Python's site
# interpreter version, matching the DEB layout.

%install
rm -rf %{buildroot}

# 1. Source tree under /usr/share/nethraops-agent/src/.
install -d -m 0755 %{buildroot}%{_datadir}/nethraops-agent/src
cp -r pyproject.toml README.md src %{buildroot}%{_datadir}/nethraops-agent/src/

# 2. systemd unit.
install -d -m 0755 %{buildroot}%{_unitdir}
install -m 0644 packaging/linux/deb/lib/systemd/system/nethraops-agent.service \
    %{buildroot}%{_unitdir}/nethraops-agent.service

# 3. Enrol helper.
install -d -m 0755 %{buildroot}%{_bindir}
install -m 0755 packaging/linux/deb/usr/bin/nethraops-agent-enroll \
    %{buildroot}%{_bindir}/nethraops-agent-enroll

# 4. install.conf.example as a sample config (marked %config(noreplace)
#    so dnf upgrade keeps operator edits).
install -d -m 0750 %{buildroot}%{_sysconfdir}/nethraops-agent
install -m 0644 packaging/linux/deb/etc/nethraops-agent/install.conf.example \
    %{buildroot}%{_sysconfdir}/nethraops-agent/install.conf.example

%files
%{_datadir}/nethraops-agent/
%{_unitdir}/nethraops-agent.service
%{_bindir}/nethraops-agent-enroll
%dir %attr(0750, root, nethraops-agent) %{_sysconfdir}/nethraops-agent
%config(noreplace) %{_sysconfdir}/nethraops-agent/install.conf.example

%pre
# Create the system user/group before files land so chown in %files works.
getent group nethraops-agent >/dev/null || groupadd --system nethraops-agent
getent passwd nethraops-agent >/dev/null || \
    useradd --system --gid nethraops-agent --no-create-home \
            --home-dir /var/lib/nethraops-agent --shell /sbin/nologin \
            --comment "NethraOps agent" nethraops-agent
exit 0

%post
# Mirrors DEBIAN/postinst. Keep the logic in sync.
USER_NAME=nethraops-agent
APP_DIR=/opt/nethraops-agent
VENV_DIR=${APP_DIR}/venv
ETC_DIR=/etc/nethraops-agent
DATA_DIR=/var/lib/nethraops-agent
LOG_DIR=/var/log/nethraops-agent
SRC_DIR=/usr/share/nethraops-agent/src
SERVICE_NAME=nethraops-agent.service
INSTALL_LOG=${LOG_DIR}/install.log

install -d -m 0755 ${APP_DIR}
install -d -m 0750 -o ${USER_NAME} -g ${USER_NAME} ${DATA_DIR}
install -d -m 0750 -o ${USER_NAME} -g ${USER_NAME} ${LOG_DIR}

log() {
    echo "[nethraops-agent post] $*"
    if [ -d "${LOG_DIR}" ]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "${INSTALL_LOG}" 2>/dev/null || true
    fi
}

if [ ! -d "${VENV_DIR}" ]; then
    log "creating venv at ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
fi
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip wheel || true
if [ -d "${SRC_DIR}" ]; then
    "${VENV_DIR}/bin/pip" install --quiet "${SRC_DIR}" || \
        log "WARN: pip install of agent source failed"
fi

ENV_FILE=${ETC_DIR}/agent.env
if [ ! -f "${ENV_FILE}" ]; then
    cat > "${ENV_FILE}" <<'ENVEOF'
NETHRAOPS_BACKEND_URL=https://monitor.example.com
NETHRAOPS_ENROLMENT_TOKEN=
NETHRAOPS_AGENT_TOKEN=
NETHRAOPS_DEVICE_TYPE=linux
NETHRAOPS_COLLECT_INTERVAL_SECONDS=15
NETHRAOPS_FLUSH_INTERVAL_SECONDS=15
NETHRAOPS_FLUSH_BATCH_SIZE=200
NETHRAOPS_MAX_BUFFER_FRAMES=10000
NETHRAOPS_LOG_LEVEL=INFO
NETHRAOPS_LOG_FORMAT=json
ENVEOF
    chown root:${USER_NAME} "${ENV_FILE}"
    chmod 0640 "${ENV_FILE}"
fi

# Pre-seeded claim flow.
CLAIM_TOKEN=""
PLATFORM_URL=""
INSTALL_CONF=${ETC_DIR}/install.conf
if [ -f "${INSTALL_CONF}" ]; then
    while IFS='=' read -r key value; do
        case "${key}" in
            CLAIM_TOKEN) CLAIM_TOKEN="${value}" ;;
            PLATFORM_URL) PLATFORM_URL="${value}" ;;
        esac
    done < "${INSTALL_CONF}"
fi

%systemd_post nethraops-agent.service

if [ -n "${CLAIM_TOKEN}" ] && [ -n "${PLATFORM_URL}" ]; then
    log "pre-seeded claim found; redeeming via ${PLATFORM_URL}/install/linux.sh"
    if curl -fsSL "${PLATFORM_URL}/install/linux.sh?claim=${CLAIM_TOKEN}" | bash; then
        systemctl restart nethraops-agent.service || true
    fi
else
    log "no pre-seeded CLAIM_TOKEN+PLATFORM_URL - run nethraops-agent-enroll"
fi

%preun
%systemd_preun nethraops-agent.service

%postun
%systemd_postun_with_restart nethraops-agent.service

if [ $1 -eq 0 ]; then
    # Full uninstall (not an upgrade). Mirror DEBIAN/postrm purge.
    rm -rf /opt/nethraops-agent
    rm -rf /etc/nethraops-agent
    rm -rf /var/lib/nethraops-agent
    rm -rf /var/log/nethraops-agent
    if getent passwd nethraops-agent >/dev/null; then
        userdel nethraops-agent >/dev/null 2>&1 || true
    fi
    if getent group nethraops-agent >/dev/null; then
        groupdel nethraops-agent >/dev/null 2>&1 || true
    fi
fi

%changelog
* Wed May 29 2026 NethraOps <engineering@nethraops.com> - 0.1.0-1
- Phase 1C: initial RPM packaging. Mirrors the DEB layout: pre-seeded
  install.conf, funnel to /install/linux.sh redemption, systemd unit
  with hardening, nethraops-agent-enroll helper.
