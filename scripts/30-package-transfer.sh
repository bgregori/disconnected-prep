#!/usr/bin/env bash
# docs/04-transfer.md
# Run on: CONNECTED bastion
#
# Packages the staged export for transfer and writes a checksum manifest.
#
# The archives are already compressed container layers. Re-compressing them
# with `tar -z` costs a lot of CPU and saves almost nothing, so this writes
# an uncompressed tar -- or, by default, leaves the directory alone and just
# generates checksums for a direct copy to removable media.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars EXPORTS_DIR EXPORT_TAG OCP_AIRGAP_ROOT
require_cmds sha256sum

SRC="${EXPORTS_DIR}/${EXPORT_TAG}"
[[ -d "${SRC}" ]] || die "No export at ${SRC}. Run ./scripts/20-mirror-to-disk.sh first."

# The first transfer must also carry the tooling; later deltas need only the
# archives. The marker lives alongside the prep tree, NOT inside the export
# directory -- a per-export marker is never present in a new dated export,
# so every delta would needlessly re-ship ~840 MB of binaries.
BIN_MARKER="${OCP_AIRGAP_ROOT}/.binaries-transferred"
if [[ "${INCLUDE_BINARIES:-auto}" == "auto" ]]; then
  if [[ -f "${BIN_MARKER}" ]]; then INCLUDE_BINARIES=false; else INCLUDE_BINARIES=true; fi
fi

if [[ "${INCLUDE_BINARIES}" == "true" ]]; then
  info "Including binaries/ and this repo (first transfer)"
  run mkdir -p "${SRC}/binaries"
  for f in openshift-client-linux.tar.gz oc-mirror.rhel9.tar.gz mirror-registry.tar.gz; do
    [[ -f "${OCP_AIRGAP_ROOT}/binaries/${f}" ]] && run cp -v "${OCP_AIRGAP_ROOT}/binaries/${f}" "${SRC}/binaries/"
  done
  # The disconnected side needs these procedures too.
  #
  # --exclude must precede the path arguments: GNU tar (RHEL 9) treats
  # options after a non-optional argument as positional and fails with
  # "--exclude has no effect", exiting non-zero. BSD tar is lenient, so
  # this only breaks on the platform that matters.
  #
  # config/prep.env is excluded deliberately -- it holds QUAY_PASSWORD, and
  # the registry host needs its own paths anyway.
  run tar -cf "${SRC}/disconnected-prep-repo.tar" \
      --exclude='.git' \
      --exclude='config/prep.env' \
      -C "$(dirname "${REPO_ROOT}")" "$(basename "${REPO_ROOT}")"
  : > "${BIN_MARKER}"
  info "Recorded ${BIN_MARKER}; later transfers will carry archives only."
  info "  Delete it to force the tooling to be included again."
else
  info "Tooling already transferred previously -- shipping archives only."
fi

info "Generating checksum manifest"
# Reads and hashes every byte, single-threaded, with no output until done:
# several minutes for 29 GB on 2 vCPU, and the far side pays it again.
info "Checksumming the bundle (minutes for a large archive; no output until it finishes)"
run_sh "cd '${SRC}' && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS"

ok "Export ready: ${SRC}"
du -sh "${SRC}" >&2
echo >&2
cat >&2 <<EOF
Transfer the whole directory to the registry host at:
    \${IMPORTS_DIR}/${EXPORT_TAG}

Before you unplug, check the destination has room:
    df -h <destination>

On arrival, verify integrity:
    cd \${IMPORTS_DIR}/${EXPORT_TAG} && sha256sum -c SHA256SUMS

Do not skip the verification step. A silently truncated multi-hundred-GB
archive fails deep inside the registry push, hours later.
EOF
