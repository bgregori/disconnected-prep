#!/usr/bin/env bash
# docs/01-prerequisites.md -- "Install the tooling"
# Run on: CONNECTED bastion
#
# The registry host gets the same binaries from the first transfer
# instead; scripts/40-stage-transfer.sh installs them there.
#
# Downloads oc, oc-mirror and mirror-registry, installs the first two to
# /usr/local/bin, and applies the SELinux + fapolicyd handling a STIG'd
# RHEL 9 host needs before freshly-written binaries will execute.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars PREP_ROOT OCP_CHANNEL
require_cmds curl tar sudo

MIRROR_REGISTRY_VERSION="${MIRROR_REGISTRY_VERSION:-1.3.9}"
BIN="${PREP_ROOT}/binaries"

run mkdir -p "${BIN}" "${PREP_ROOT}/config" "${CACHE_DIR}" "${MIRROR_OUT}" "${EXPORTS_DIR}"
cd "${BIN}"

# oc-mirror is pulled from the same channel as the payload, not from
# .../clients/ocp/latest -- a newer oc-mirror can write archive metadata an
# older cluster's tooling does not expect.
base="https://mirror.openshift.com/pub/openshift-v4/${OCP_ARCH:-x86_64}/clients/ocp/${OCP_CHANNEL}"
[[ "${OCP_ARCH}" == "amd64" ]] && base="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_CHANNEL}"

info "Downloading client tooling from ${base}"
run curl -fLO "${base}/openshift-client-linux.tar.gz"
run curl -fLO "${base}/oc-mirror.rhel9.tar.gz"

info "Downloading mirror-registry ${MIRROR_REGISTRY_VERSION}"
run curl -fLO "https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/mirror-registry/${MIRROR_REGISTRY_VERSION}/mirror-registry.tar.gz"

info "Installing oc and oc-mirror to /usr/local/bin"
run sudo tar -xzf openshift-client-linux.tar.gz -C /usr/local/bin oc
run sudo tar -xzf oc-mirror.rhel9.tar.gz -C /usr/local/bin oc-mirror
run sudo chown root:root /usr/local/bin/oc /usr/local/bin/oc-mirror
run sudo chmod 0755 /usr/local/bin/oc /usr/local/bin/oc-mirror

# SELinux: a file written by tar into /usr/local/bin inherits the wrong label
# and will be denied execution under a targeted policy.
run sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror

# fapolicyd: STIG requires application allowlisting. Unlisted binaries are
# refused with "Operation not permitted" even as root.
if command -v fapolicyd-cli >/dev/null 2>&1 && systemctl is-active --quiet fapolicyd; then
  info "fapolicyd is active -- adding binaries to the allowlist"
  run sudo fapolicyd-cli --file add /usr/local/bin/oc
  run sudo fapolicyd-cli --file add /usr/local/bin/oc-mirror
  run sudo fapolicyd-cli --update
else
  info "fapolicyd not active -- skipping allowlist step"
fi

# Assert rather than report. A binary that does not execute is the whole
# failure mode this step exists to prevent, and fapolicyd takes a moment to
# pick up a trust database update.
ok "oc: $(assert_executes /usr/local/bin/oc)"
if (umask 0022; oc-mirror version --v2 >/dev/null 2>&1); then
  ok "oc-mirror: executes"
else
  die "oc-mirror does not execute. See docs/02-fips-stig-rhel9.md."
fi

cat >&2 <<EOF

Next: place your Red Hat pull secret at
    ${RH_PULL_SECRET}
Download it from https://console.redhat.com/openshift/downloads
(bottom of the downloads list), then run ./scripts/00-preflight.sh
EOF
