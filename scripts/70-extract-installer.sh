#!/usr/bin/env bash
# docs/07-verify.md -- "Extract the FIPS installer"
# Run on: REGISTRY HOST
#
# Extracts openshift-install-fips from the release payload in the local
# registry.
#
# This doubles as the strongest single proof the mirror works: it exercises
# registry auth, TLS trust, IDMS resolution and release payload completeness
# in one command. If this succeeds, the hard part of prep is done.
#
# Use openshift-install-fips, not openshift-install: the FIPS-validated
# binary is required when install-config.yaml sets `fips: true`.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars OCP_AIRGAP_ROOT OCP_VERSION OCP_ARCH REGISTRY_HOST REGISTRY_PORT MIRROR_PULL_SECRET IMPORTS_DIR EXPORT_TAG
require_cmds oc
check_version_matches_import

BIN="${OCP_AIRGAP_ROOT}/binaries"
run mkdir -p "${BIN}"

IDMS="${IMPORTS_DIR}/${EXPORT_TAG}/working-dir/cluster-resources/idms-oc-mirror.yaml"
[[ -f "${IDMS}" ]] || die "No IDMS at ${IDMS}. Run ./scripts/60-push-to-registry.sh first."

# oc-mirror v2 publishes the release payload under openshift/release-images.
RELEASE="$(registry_ref)/openshift/release-images:${OCP_VERSION}-${RELEASE_ARCH:-x86_64}"
info "Extracting from ${RELEASE}"

# --idms-file must be an absolute path; oc resolves it relative to cwd and a
# relative path here is a common and confusing failure.
# NOTE: `oc adm release extract` takes -a/--registry-config, NOT --authfile.
# oc-mirror uses --authfile and oc uses -a; mixing them up gives
# "error: unknown flag: --authfile".
run oc adm release extract \
  --registry-config "${MIRROR_PULL_SECRET}" \
  --command=openshift-install-fips \
  --from="${RELEASE}" \
  --to="${BIN}" \
  --idms-file="${IDMS}"

run chmod +x "${BIN}/openshift-install-fips"

# Fourth binary this workflow extracts and runs, and fapolicyd denies it for
# the same reason as the other three: it came out of an archive, not an RPM.
run sudo restorecon -v "${BIN}/openshift-install-fips" || true
fapolicyd_trust "${BIN}/openshift-install-fips"

echo >&2
ok "Extracted: ${BIN}/openshift-install-fips"
run "${BIN}/openshift-install-fips" version

cat >&2 <<EOF

The version above must match OCP_VERSION (${OCP_VERSION}).

This binary, not the one from mirror.openshift.com, is what the install side
must use for a cluster with fips: true.

Next: ./scripts/80-verify-mirror.sh
EOF
