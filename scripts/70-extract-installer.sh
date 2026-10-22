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

# Trust lets the installer execute, not do its job. `agent create image`
# reads shared libraries it unpacked itself -- libnmstate.so into
# ~/.cache/agent/files_cache/, ldlinux.c32 out of the base ISO into $TMPDIR --
# to pack them into the ISO, and the STIG policy denies opening any untrusted
# shared library, even to read it (41-shared-obj.rules). The ISO fails with
#   open .../files_cache/libnmstate.so.2.2.60: operation not permitted
# This lets this one binary read shared libraries. perm=open only: loading one
# as code needs perm=execute, which stays denied. Numbered 35 to precede
# 41-shared-obj.rules. exe= matches by path, so a copy run from anywhere else
# needs its own rule -- see docs/08-handoff.md.
RULES_FILE=/etc/fapolicyd/rules.d/35-openshift-install.rules
RULE="allow perm=open exe=${BIN}/openshift-install-fips : ftype=application/x-sharedlib"
if command -v fagenrules >/dev/null 2>&1 && systemctl is-active --quiet fapolicyd 2>/dev/null; then
  if [[ "$(sudo cat "${RULES_FILE}" 2>/dev/null)" == "${RULE}" ]]; then
    info "fapolicyd: ${RULES_FILE} already in place"
  else
    info "fapolicyd: letting openshift-install-fips read the shared libraries it unpacks"
    run_sh "printf '%s\n' '${RULE}' | sudo install -m 0644 -o root -g fapolicyd /dev/stdin ${RULES_FILE}"
    run sudo fagenrules --load
  fi
fi

echo >&2
ok "Extracted: ${BIN}/openshift-install-fips"
run "${BIN}/openshift-install-fips" version

cat >&2 <<EOF

The version above must match OCP_VERSION (${OCP_VERSION}).

This binary, not the one from mirror.openshift.com, is what the install side
must use for a cluster with fips: true.

Next: ./scripts/80-verify-mirror.sh
EOF
