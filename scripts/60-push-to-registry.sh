#!/usr/bin/env bash
# docs/07-push-to-registry.md
# Run on: REGISTRY HOST
#
# Disk-to-mirror (d2m). Unpacks the transferred archive and pushes its
# contents into the local Quay.
#
# This step also generates the cluster manifests (IDMS, ITMS, CatalogSource,
# ClusterCatalog, signature ConfigMaps). They are written to the --from
# path, i.e. ${IMPORTS_DIR}/${EXPORT_TAG}/working-dir/cluster-resources/.
# Those files are the main artifact the install side consumes -- see
# docs/09-handoff.md.
#
# --config is required even for d2m; it selects which subset of the archive
# to publish.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars IMPORTS_DIR EXPORT_TAG CACHE_DIR MIRROR_PULL_SECRET REGISTRY_HOST REGISTRY_PORT
require_cmds oc-mirror

FROM_DIR="$(cd "${IMPORTS_DIR}/${EXPORT_TAG}" 2>/dev/null && pwd)" \
  || die "No import at ${IMPORTS_DIR}/${EXPORT_TAG}"

compgen -G "${FROM_DIR}/mirror_*.tar" >/dev/null \
  || die "No mirror_*.tar in ${FROM_DIR}"

CFG="${IMAGESET_CONFIG}"
[[ -f "${CFG}" ]] || CFG="${FROM_DIR}/imageset-config.yaml"
[[ -f "${CFG}" ]] || die "No ImageSetConfiguration found (checked ${IMAGESET_CONFIG} and ${FROM_DIR})"
info "Using ImageSetConfiguration: ${CFG}"

# Integrity first. A truncated archive fails hours into the push.
#
# This hashes the whole archive, which takes minutes on a small host (~5 min
# for 29 GB on 2 vCPU). The push is resumable and you may well run it more
# than once -- set SKIP_CHECKSUM=true on a retry once the first run has
# already verified the same files.
VERIFIED_MARKER="${FROM_DIR}/.checksum-verified"

if [[ "${SKIP_CHECKSUM:-false}" == "true" ]]; then
  warn "SKIP_CHECKSUM=true -- not verifying archive integrity."
elif [[ -f "${VERIFIED_MARKER}" ]]; then
  ok "Archive already verified on $(cat "${VERIFIED_MARKER}") -- skipping re-check."
  info "  Delete ${VERIFIED_MARKER} to force re-verification."
elif [[ -f "${FROM_DIR}/SHA256SUMS" ]]; then
  info "Verifying transfer integrity (minutes for a large archive)"
  run_sh "cd '${FROM_DIR}' && sha256sum -c SHA256SUMS --quiet" \
    || die "Checksum mismatch. Re-transfer before proceeding."
  date -u +%Y-%m-%dT%H:%M:%SZ > "${VERIFIED_MARKER}" 2>/dev/null || true
  ok "Archive integrity verified"
else
  warn "No SHA256SUMS in ${FROM_DIR} -- skipping integrity check."
fi

require_space "${CACHE_DIR}" "${MIN_CACHE_GB:-150}"
run mkdir -p "${CACHE_DIR}"
use_mirror_tmpdir

extra=()
[[ "${PARALLEL_IMAGES:-}" ]] && extra+=(--parallel-images "${PARALLEL_IMAGES}")
[[ "${PARALLEL_LAYERS:-}" ]] && extra+=(--parallel-layers "${PARALLEL_LAYERS}")
[[ "${USE_MAX_NESTED_PATHS:-false}" == "true" ]] && extra+=(--max-nested-paths "${MAX_NESTED_PATHS:-2}")

advise_tmux

info "Pushing to docker://$(registry_ref)"
# umask relaxed: oc-mirror writes cluster-resources that other accounts read.
#
# A partial failure (some images copied, some not) exits non-zero but still
# generates the cluster resources. Capture the status rather than letting
# `set -e` abort here -- otherwise the run dies silently and you never learn
# how much succeeded or which images failed.
rc=0
run_sh "umask 0022 && oc-mirror --v2 \
  --config '${CFG}' \
  --from 'file://${FROM_DIR}' \
  --cache-dir '${CACHE_DIR}' \
  --authfile '${MIRROR_PULL_SECRET}' \
  ${extra[*]} \
  docker://$(registry_ref)" || rc=$?

echo >&2
if (( rc != 0 )); then
  warn "oc-mirror exited ${rc}: not every image was mirrored."
  errlog=$(ls -t "${FROM_DIR}/working-dir/logs/mirroring_errors_"*.txt 2>/dev/null | head -1)
  if [[ -n "${errlog}" ]]; then
    warn "Failed images (${errlog}):"
    sed -e 's/^/    /' -e 's/\(.\{150\}\).*/\1.../' "${errlog}" >&2
  fi
  cat >&2 <<EOF

  Transient blob/token errors are common when pushing many images at once to
  a small registry host. The push is resumable and already-pushed images are
  skipped, so the usual remedy is to lower parallelism and run it again:

      PARALLEL_IMAGES=2 PARALLEL_LAYERS=2 SKIP_CHECKSUM=true $0

  Multi-architecture images (manifest lists) are mirrored one architecture at
  a time; a failure on one of them fails the whole image.
EOF
fi

CR="${FROM_DIR}/working-dir/cluster-resources"
if [[ -d "${CR}" ]] && [[ -n "$(ls -A "${CR}" 2>/dev/null)" ]]; then
  ok "Cluster resources generated:"
  ls -1 "${CR}" >&2
else
  warn "Expected cluster-resources at ${CR} but none were generated."
fi

(( rc == 0 )) || die "Push incomplete. Resolve the failures above before handing off."

info "Next: ./scripts/70-extract-installer.sh, then ./scripts/80-verify-mirror.sh"
