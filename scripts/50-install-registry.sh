#!/usr/bin/env bash
# docs/05-registry.md
# Run on: REGISTRY HOST
#
# Installs Red Hat mirror-registry (standalone Quay), trusts its CA, and
# writes the auth file used for the registry push.
#
# Two STIG-specific workarounds are applied here; both are explained in
# docs/appendix-fips-stig.md:
#   1. umask 0022 for the installer, because a 0077/0027 umask produces
#      config directories the Quay container cannot read.
#   2. A systemd drop-in that re-applies permissions on every start, because
#      the installer is not the only thing that writes those directories.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars OCP_AIRGAP_ROOT QUAY_ROOT REGISTRY_HOST REGISTRY_PORT QUAY_USER QUAY_PASSWORD MIRROR_PULL_SECRET IMPORTS_DIR EXPORT_TAG
require_cmds tar sudo base64

[[ "${QUAY_PASSWORD}" == "CHANGE-ME-before-running" ]] && die "Set QUAY_PASSWORD in config/prep.env."
(( ${#QUAY_PASSWORD} >= 8 )) || die "Quay requires a password of at least 8 characters."

BIN="${OCP_AIRGAP_ROOT}/binaries"

# Image data goes to podman's volume store, not to --quayRoot (which holds
# only config and certs). Check the filesystem that will actually fill up.
if command -v podman >/dev/null 2>&1; then
  GRAPH_ROOT="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)"
  if [[ -n "${GRAPH_ROOT}" ]]; then
    info "Quay images will be stored under: ${GRAPH_ROOT}"
    require_space "${GRAPH_ROOT}" "${MIN_QUAY_GB:-200}"
  fi
fi
# mirror-registry drives an embedded Ansible playbook as the invoking user,
# which cannot create a directory in a root-owned parent such as /opt. Make
# it here, owned by this account, with an explicit mode: under the STIG
# umask 0077 it would otherwise be 0700 and Quay could not read it.
if [[ ! -d "${QUAY_ROOT}" ]]; then
  run sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 0755 "${QUAY_ROOT}"
fi
require_space "${QUAY_ROOT}" "${MIN_QUAYROOT_GB:-1}"

if [[ ! -x "${BIN}/mirror-registry" ]]; then
  # The transfer lands the tarball under imports/<tag>/binaries/, not here.
  # 40-stage-transfer.sh normally copies it across; fall back to the import
  # directory so a hand-run that skipped that step still works.
  TARBALL="${BIN}/mirror-registry.tar.gz"
  if [[ ! -f "${TARBALL}" ]]; then
    IMPORTED="${IMPORTS_DIR}/${EXPORT_TAG}/binaries/mirror-registry.tar.gz"
    [[ -f "${IMPORTED}" ]] || die "No mirror-registry.tar.gz in ${BIN} or ${IMPORTED}.
Run ./scripts/40-stage-transfer.sh first -- see docs/05-registry.md."
    info "Not staged in ${BIN}; using ${IMPORTED}"
    run mkdir -p "${BIN}"
    run cp "${IMPORTED}" "${TARBALL}"
  fi
  run tar -xzf "${TARBALL}" -C "${BIN}"
fi

# --- firewall --------------------------------------------------------------

if systemctl is-active --quiet firewalld 2>/dev/null; then
  info "Opening ${REGISTRY_PORT}/tcp"
  run sudo firewall-cmd --add-port "${REGISTRY_PORT}/tcp" --permanent
  run sudo firewall-cmd --reload
else
  warn "firewalld inactive -- ensure ${REGISTRY_PORT}/tcp is reachable from the cluster nodes."
fi

# --- install ---------------------------------------------------------------

info "Installing Quay at ${QUAY_ROOT} for ${REGISTRY_HOST}"
# umask must be relaxed for the duration of the install only.
run_sh "umask 0022 && '${BIN}/mirror-registry' install \
  --quayHostname '${REGISTRY_HOST}' \
  --quayRoot '${QUAY_ROOT}' \
  --initUser '${QUAY_USER}' \
  --initPassword '${QUAY_PASSWORD}'"

# --- permission drop-in (applied AFTER install creates the units) ----------

info "Installing systemd drop-in to keep Quay config readable across restarts"
DROPIN="${HOME}/.config/systemd/user/quay-app.service.d"
run mkdir -p "${DROPIN}"
cat > "${DROPIN}/fix-perms.conf" <<EOF
[Service]
# A restrictive STIG umask causes these directories to be recreated with
# modes the Quay container cannot read. Re-apply usable modes on each start.
ExecStartPre=/bin/bash -c 'chmod -R 755 ${QUAY_ROOT}/quay-config ${QUAY_ROOT}/quay-rootCA; chmod 644 ${QUAY_ROOT}/quay-config/* ${QUAY_ROOT}/quay-rootCA/*'
EOF
run systemctl --user daemon-reload
run systemctl --user restart quay-app.service || warn "Could not restart quay-app.service; check 'systemctl --user status quay-app'"

# Survive logout.
run sudo loginctl enable-linger "${USER}"

# --- CA trust --------------------------------------------------------------

CA="${QUAY_ROOT}/quay-rootCA/rootCA.pem"
[[ -f "${CA}" ]] || die "Expected CA at ${CA} but it is missing."

info "Adding the Quay CA to the system trust store"
# oc-mirror reads certificate trust from the host store, not from a flag.
run sudo cp -v "${CA}" /etc/pki/ca-trust/source/anchors/quay-rootCA.pem
run sudo update-ca-trust

# --- auth file -------------------------------------------------------------

info "Writing ${MIRROR_PULL_SECRET}"
run mkdir -p "$(dirname "${MIRROR_PULL_SECRET}")"
QUAY_AUTH=$(printf '%s:%s' "${QUAY_USER}" "${QUAY_PASSWORD}" | base64 -w0)
cat > "${MIRROR_PULL_SECRET}" <<EOF
{"auths":{"$(registry_ref)":{"auth":"${QUAY_AUTH}"}}}
EOF
run chmod 600 "${MIRROR_PULL_SECRET}"

# --- verify ----------------------------------------------------------------

# mirror-registry reports success as soon as the containers are started, but
# Quay needs another minute or two to finish initialising -- longer on a small
# host. Verifying before it is ready produces a confusing auth failure.
info "Waiting for Quay to become available (can take several minutes)"
ready=false
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 \
         "https://$(registry_ref)/health/instance" 2>/dev/null || true)
  if [[ "${code}" == "200" ]]; then ready=true; break; fi
  printf '\r  waiting... %3ds (HTTP %s)' $((i*5)) "${code:-000}" >&2
  sleep 5
done
echo >&2
[[ "${ready}" == "true" ]] \
  || die "Quay did not become healthy. Check: podman logs quay-app"
ok "Quay is healthy"

info "Verifying login"
# --password-stdin keeps the password out of the process list, and the
# explicit --username prevents podman from falling back to an interactive
# prompt, which would hang a non-interactive run.
if command -v podman >/dev/null 2>&1; then
  printf '%s' "${QUAY_PASSWORD}" | run podman login \
      --username "${QUAY_USER}" --password-stdin \
      --authfile "${MIRROR_PULL_SECRET}" \
      "$(registry_ref)" \
    || die "Could not log in to $(registry_ref). Check DNS, firewall, and CA trust."
fi

ok "Registry ready at https://$(registry_ref)"
cat >&2 <<EOF

Confirm from a machine that is NOT this host -- the cluster nodes must
resolve and reach ${REGISTRY_HOST}, not just localhost:
    curl -I https://$(registry_ref)/v2/

Next: ./scripts/60-push-to-registry.sh
EOF
