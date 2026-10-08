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

# Quay reads its config as a non-root UID inside the container, which
# rootless podman maps to a subuid on the host: container QUAY_CONTAINER_UID
# -> subuid_base + QUAY_CONTAINER_UID - 1. Grant that one UID and keep the
# directories closed to every other account, because ssl.key and
# rootCA.key live in them.
SUBUID_BASE="$(awk -F: -v u="$(id -un)" '$1 == u {print $2; exit}' /etc/subuid)"
[[ -n "${SUBUID_BASE}" ]] || die "No /etc/subuid entry for $(id -un); rootless podman cannot map UIDs."
QUAY_HOST_UID=$(( SUBUID_BASE + ${QUAY_CONTAINER_UID:-1001} - 1 ))
info "Quay reads its config as host UID ${QUAY_HOST_UID} (subuid ${SUBUID_BASE} + ${QUAY_CONTAINER_UID:-1001} - 1)"

run install -d -m 0750 "${QUAY_ROOT}/quay-config" "${QUAY_ROOT}/quay-rootCA"
run setfacl -m "u:${QUAY_HOST_UID}:rX" "${QUAY_ROOT}/quay-config" "${QUAY_ROOT}/quay-rootCA"

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

# Before the install, not after: Quay runs as user systemd services and
# mirror-registry starts them over its own SSH session to localhost. With
# Linger=no systemd tears that user manager down with the session, the pod
# is created with no running containers, and the installer fails polling
# /health/instance with a TLS EOF that looks like a certificate problem.
run sudo loginctl enable-linger "${USER}"

info "Installing Quay at ${QUAY_ROOT} for ${REGISTRY_HOST}"

# The installer does not write quay-config from THIS shell: it sshes to
# localhost with a generated key and runs Ansible there, so the files are
# created under the umask PAM gives that session -- 0077 on a STIG build,
# whatever this shell is set to. Ansible also renames each file into place,
# so a default ACL on the directory is not inherited either. The only lever
# is the umask of the installer's own session, which bash picks up from
# ~/.bashrc even for the non-interactive command sshd runs.
#
# That line is a finding while it exists (V-258044 / RHEL-09-411025: umask
# 077 for all local interactive user accounts), so it is removed on the way
# out -- by trap, so an interrupted or failed install cannot leave it behind.
UMASK_LINE="umask 0022   # disconnected-prep: mirror-registry install only"
restore_umask() {
  if grep -qxF "${UMASK_LINE}" "${HOME}/.bashrc" 2>/dev/null; then
    grep -vxF "${UMASK_LINE}" "${HOME}/.bashrc" > "${HOME}/.bashrc.$$" \
      && mv "${HOME}/.bashrc.$$" "${HOME}/.bashrc"
    info "Removed the temporary umask from ~/.bashrc (V-258044)"
  fi
}
trap restore_umask EXIT

warn "Temporarily relaxing this account's umask for the install (V-258044)."
printf '%s\n' "${UMASK_LINE}" >> "${HOME}/.bashrc"

# NOT via run_sh: it echoes the command it runs, and this one carries the
# password. The transcript is accreditation evidence -- it must not contain
# a credential. (ps still sees it for the duration; mirror-registry has no
# stdin option for the password.)
info "+ ${BIN}/mirror-registry install --quayHostname ${REGISTRY_HOST} --quayRoot ${QUAY_ROOT} --initUser ${QUAY_USER} --initPassword <redacted>"
"${BIN}/mirror-registry" install \
  --quayHostname "${REGISTRY_HOST}" \
  --quayRoot "${QUAY_ROOT}" \
  --initUser "${QUAY_USER}" \
  --initPassword "${QUAY_PASSWORD}"

restore_umask
trap - EXIT

# --- permission drop-in (applied AFTER install creates the units) ----------

info "Installing systemd drop-in to keep Quay config readable across restarts"
DROPIN="${HOME}/.config/systemd/user/quay-app.service.d"
run mkdir -p "${DROPIN}"
cat > "${DROPIN}/fix-perms.conf" <<EOF
[Service]
# Restarts and upgrades recreate these directories, and a recreated
# directory has no ACL. Re-grant the mapped UID on every start.
ExecStartPre=/bin/bash -c 'setfacl -R -m u:${QUAY_HOST_UID}:rX ${QUAY_ROOT}/quay-config ${QUAY_ROOT}/quay-rootCA'
EOF
run systemctl --user daemon-reload
run systemctl --user restart quay-app.service || warn "Could not restart quay-app.service; check 'systemctl --user status quay-app'"

# --- CA trust --------------------------------------------------------------

CA="${QUAY_ROOT}/quay-rootCA/rootCA.pem"
[[ -f "${CA}" ]] || die "Expected CA at ${CA} but it is missing."

info "Adding the Quay CA to the system trust store"
# oc-mirror reads certificate trust from the host store, not from a flag.
run sudo cp -v "${CA}" /etc/pki/ca-trust/source/anchors/quay-rootCA.pem
run sudo update-ca-trust

# --- wait for Quay ---------------------------------------------------------

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

# --- auth file -------------------------------------------------------------

# `podman login --authfile` writes the file AND proves the credentials in one
# step, and keys it by exactly the string we push to -- which is the usual way
# an auth file goes wrong (host vs host:port are different keys). Writing the
# JSON by hand first, as earlier versions did, only to have podman rewrite it,
# bought nothing.
#
# --password-stdin keeps the password out of the process list, and the
# explicit --username prevents podman from falling back to an interactive
# prompt, which would hang a non-interactive run.
info "Writing ${MIRROR_PULL_SECRET} via podman login"
run mkdir -p "$(dirname "${MIRROR_PULL_SECRET}")"
if command -v podman >/dev/null 2>&1; then
  printf '%s' "${QUAY_PASSWORD}" | run podman login \
      --username "${QUAY_USER}" --password-stdin \
      --authfile "${MIRROR_PULL_SECRET}" \
      "$(registry_ref)" \
    || die "Could not log in to $(registry_ref). Check DNS, firewall, and CA trust."
else
  warn "podman not found -- writing ${MIRROR_PULL_SECRET} unverified."
  QUAY_AUTH=$(printf '%s:%s' "${QUAY_USER}" "${QUAY_PASSWORD}" | base64 -w0)
  cat > "${MIRROR_PULL_SECRET}" <<EOF
{"auths":{"$(registry_ref)":{"auth":"${QUAY_AUTH}"}}}
EOF
fi
run chmod 600 "${MIRROR_PULL_SECRET}"

ok "Registry ready at https://$(registry_ref)"
cat >&2 <<EOF

Confirm from a machine that is NOT this host -- the cluster nodes must
resolve and reach ${REGISTRY_HOST}, not just localhost:
    curl -I https://$(registry_ref)/v2/

Next: ./scripts/60-push-to-registry.sh
EOF
