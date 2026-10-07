#!/usr/bin/env bash
# docs/05-registry.md -- "Stage the transferred tooling"
# Run on: REGISTRY HOST, after the first transfer has landed
#
# The transfer deposits everything under ${IMPORTS_DIR}/${EXPORT_TAG}/, but
# the rest of the disconnected-side tooling expects the same prep tree
# layout as the connected bastion -- 50-install-registry.sh looks for
# ${PREP_ROOT}/binaries/mirror-registry.tar.gz, and prep.env points
# MIRROR_PULL_SECRET at ${PREP_ROOT}/binaries/. This bridges the two.
#
# Idempotent: safe to re-run, and a no-op on later deltas, which carry
# archives only.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars PREP_ROOT IMPORTS_DIR EXPORT_TAG
require_cmds tar sudo

IMPORT="${IMPORTS_DIR}/${EXPORT_TAG}"
BIN="${PREP_ROOT}/binaries"

[[ -d "${IMPORT}" ]] || die "No import at ${IMPORT}. Transfer it first -- see docs/04-transfer.md."

run mkdir -p "${BIN}" "${PREP_ROOT}/config" "${CACHE_DIR}"

if [[ -d "${IMPORT}/binaries" ]]; then
  info "Staging tooling from ${IMPORT}/binaries into ${BIN}"
  run_sh "cp -v '${IMPORT}'/binaries/* '${BIN}/'"
else
  info "No binaries/ in this import -- a delta transfer carries archives only."
  [[ -f "${BIN}/mirror-registry.tar.gz" ]] \
    || die "No binaries/ here and none staged previously in ${BIN}.
This looks like a first transfer packaged without the tooling. On the
connected bastion, delete ${PREP_ROOT}/.binaries-transferred and re-run
scripts/30-package-transfer.sh."
fi

# --- install oc and oc-mirror on THIS host ---------------------------------
#
# The fapolicyd trust database is per-host: allowlisting these on the
# connected bastion does nothing here.

if [[ -f "${BIN}/openshift-client-linux.tar.gz" ]]; then
  info "Installing oc and oc-mirror to /usr/local/bin"
  run sudo tar -xzf "${BIN}/openshift-client-linux.tar.gz" -C /usr/local/bin oc
  run sudo tar -xzf "${BIN}/oc-mirror.rhel9.tar.gz" -C /usr/local/bin oc-mirror
  run sudo chown root:root /usr/local/bin/oc /usr/local/bin/oc-mirror
  run sudo chmod 0755 /usr/local/bin/oc /usr/local/bin/oc-mirror

  # tar writes files with the extraction context's SELinux label, not the
  # bin_t that /usr/local/bin expects. Relabel before trusting, because
  # relabelling changes the file.
  run sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror

  if command -v fapolicyd-cli >/dev/null 2>&1 && systemctl is-active --quiet fapolicyd; then
    info "fapolicyd is active -- adding binaries to the allowlist"
    run sudo fapolicyd-cli --file add /usr/local/bin/oc
    run sudo fapolicyd-cli --file add /usr/local/bin/oc-mirror
    run sudo fapolicyd-cli --update
  else
    info "fapolicyd not active -- skipping allowlist step"
  fi
else
  info "No client tarballs staged -- assuming oc/oc-mirror are already installed."
fi

# Assert rather than report: a binary that does not execute is the whole
# failure mode the SELinux/fapolicyd handling above exists to prevent.
ok "oc: $(assert_executes /usr/local/bin/oc)"
if (umask 0022; oc-mirror version --v2 >/dev/null 2>&1); then
  ok "oc-mirror: executes"
else
  die "oc-mirror does not execute. See docs/appendix-fips-stig.md."
fi

command -v podman >/dev/null 2>&1 \
  || warn "podman is not installed. mirror-registry requires it and does not supply it."

cat >&2 <<EOF

Staged into ${BIN}. Next:
    ROLE=disconnected ./scripts/00-preflight.sh
    ./scripts/50-install-registry.sh
EOF
