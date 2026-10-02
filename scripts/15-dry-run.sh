#!/usr/bin/env bash
# docs/03-plan-your-content.md -- "Validate before you pull"
# Run on: CONNECTED bastion
#
# Dry run: resolves the ImageSetConfiguration and writes the full list of
# images it would mirror, without downloading anything. Takes minutes rather
# than hours and catches the expensive mistakes -- a misspelled package name,
# a channel that does not exist, a version outside the channel.
#
# Produces, under ${MIRROR_OUT}/working-dir/dry-run/:
#   mapping.txt  -- every source -> destination image mapping
#   missing.txt  -- images not yet in the local cache (i.e. the real download)

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars MIRROR_OUT CACHE_DIR IMAGESET_CONFIG RH_PULL_SECRET
require_cmds oc-mirror
use_oc_mirror_umask

[[ -f "${IMAGESET_CONFIG}" ]] || die "No ImageSetConfiguration at ${IMAGESET_CONFIG}"

run mkdir -p "${MIRROR_OUT}" "${CACHE_DIR}"

run oc-mirror --v2 \
  --config "${IMAGESET_CONFIG}" \
  --cache-dir "${CACHE_DIR}" \
  --authfile "${RH_PULL_SECRET}" \
  --dry-run \
  "file://${MIRROR_OUT}"

dry="${MIRROR_OUT}/working-dir/dry-run"
echo >&2
if [[ -f "${dry}/mapping.txt" ]]; then
  ok "Images resolved: $(wc -l < "${dry}/mapping.txt")"
  info "Full mapping: ${dry}/mapping.txt"
fi
if [[ -f "${dry}/missing.txt" ]]; then
  ok "Images still to download: $(wc -l < "${dry}/missing.txt")"
  info "Not yet cached:  ${dry}/missing.txt"
fi

cat >&2 <<'EOF'

Review mapping.txt before mirroring. Things worth checking:
  - Every operator you expect is present.
  - No unexpected architectures.
  - Release payload count looks like one version, not a whole z-stream range.

A dry run cannot tell you the byte size of the download. For that, see
./scripts/25-estimate-size.sh
EOF
