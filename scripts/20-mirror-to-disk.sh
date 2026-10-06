#!/usr/bin/env bash
# docs/04-connected-mirror.md -- "Run the mirror"
# Run on: CONNECTED bastion
#
# Mirror-to-disk (m2d). Pulls everything named in the ImageSetConfiguration
# into tar archives under ${MIRROR_OUT}.
#
# ${MIRROR_OUT} is intentionally the SAME directory on every run. oc-mirror
# keeps its incremental history in ${MIRROR_OUT}/working-dir/.history/ and
# uses it to emit only new blobs on subsequent runs. Pointing at a fresh
# directory produces a full archive every time.
#
# oc-mirror deletes any pre-existing mirror_*.tar in ${MIRROR_OUT} before it
# starts. This script copies archives out to a dated export directory after
# each run so previous bundles survive.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars PREP_ROOT MIRROR_OUT CACHE_DIR IMAGESET_CONFIG RH_PULL_SECRET EXPORT_TAG
require_cmds oc-mirror
use_oc_mirror_umask

[[ -f "${IMAGESET_CONFIG}" ]] || die "No ImageSetConfiguration at ${IMAGESET_CONFIG} (see docs/03-plan-your-content.md)"
[[ -f "${RH_PULL_SECRET}"  ]] || die "No pull secret at ${RH_PULL_SECRET}"

run mkdir -p "${MIRROR_OUT}" "${CACHE_DIR}" "${EXPORTS_DIR}/${EXPORT_TAG}"
use_mirror_tmpdir

if [[ -d "${MIRROR_OUT}/working-dir/.history" ]]; then
  info "Incremental history found -- this run produces a DIFFERENTIAL archive."
else
  info "No history in ${MIRROR_OUT} -- this run produces a FULL archive."
fi

if compgen -G "${MIRROR_OUT}/mirror_*.tar" >/dev/null; then
  warn "oc-mirror will DELETE these archives from ${MIRROR_OUT} before starting:"
  ls -1sh "${MIRROR_OUT}"/mirror_*.tar >&2
  warn "They should already have been transferred. Previous exports under"
  warn "${EXPORTS_DIR}/ are not affected."
  confirm "Proceed?"
fi

# Long run. Keep it alive across a dropped SSH session.
advise_tmux

extra=()
[[ "${PARALLEL_IMAGES:-}" ]] && extra+=(--parallel-images "${PARALLEL_IMAGES}")
[[ "${PARALLEL_LAYERS:-}" ]] && extra+=(--parallel-layers "${PARALLEL_LAYERS}")
[[ "${STRICT_ARCHIVE:-false}" == "true" ]] && extra+=(--strict-archive)

info "Starting mirror-to-disk. Logs: ${MIRROR_OUT}/working-dir/logs/"
run oc-mirror --v2 \
  --config "${IMAGESET_CONFIG}" \
  --cache-dir "${CACHE_DIR}" \
  --authfile "${RH_PULL_SECRET}" \
  "${extra[@]}" \
  "file://${MIRROR_OUT}"

# Stage a dated, immutable copy for transport.
info "Staging archives to ${EXPORTS_DIR}/${EXPORT_TAG}/"
run cp -v "${MIRROR_OUT}"/mirror_*.tar "${EXPORTS_DIR}/${EXPORT_TAG}/"
run cp -v "${IMAGESET_CONFIG}" "${EXPORTS_DIR}/${EXPORT_TAG}/imageset-config.yaml"

ok "Mirror complete."
du -sh "${EXPORTS_DIR}/${EXPORT_TAG}" >&2
info "Next: ./scripts/30-package-transfer.sh"
