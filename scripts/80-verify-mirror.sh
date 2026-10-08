#!/usr/bin/env bash
# docs/07-verify.md -- the gate
# Run on: REGISTRY HOST
#
# Pass/fail checks that the mirror is complete and usable. Run this before
# handing anything to the install team. Every failure here is far cheaper to
# fix now than after someone has booted an ISO.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars OCP_VERSION REGISTRY_HOST REGISTRY_PORT MIRROR_PULL_SECRET OCP_AIRGAP_ROOT IMPORTS_DIR EXPORT_TAG
require_cmds oc

REG="$(registry_ref)"
CR="${IMPORTS_DIR}/${EXPORT_TAG}/working-dir/cluster-resources"
pass=0; fail=0
_p() { ok "$1"; pass=$((pass+1)); }
_f() { warn "$1"; fail=$((fail+1)); }

echo >&2; info "=== Mirror verification: ${REG} ==="; echo >&2

# 1 -- registry API reachable over TLS using the system trust store
if curl -sSf -m 15 -o /dev/null "https://${REG}/v2/" 2>/dev/null \
   || curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${REG}/v2/" 2>/dev/null | grep -q '^401'; then
  _p "Registry API reachable over TLS (system trust store accepted the CA)"
else
  _f "Cannot reach https://${REG}/v2/ -- check DNS, firewall, and update-ca-trust"
fi

# 2 -- release payload present and pullable
if run oc adm release info \
     --registry-config "${MIRROR_PULL_SECRET}" \
     "${REG}/openshift/release-images:${OCP_VERSION}-${RELEASE_ARCH:-x86_64}" \
     -o json >/tmp/relinfo.json 2>/dev/null; then
  n=$(python3 -c 'import json;print(len(json.load(open("/tmp/relinfo.json"))["references"]["spec"]["tags"]))' 2>/dev/null || echo '?')
  _p "Release payload ${OCP_VERSION} present (${n} component images)"
else
  _f "Release payload ${OCP_VERSION} missing or unreadable"
fi

# 3 -- FIPS installer extracted and version-matched
if [[ -x "${OCP_AIRGAP_ROOT}/binaries/openshift-install-fips" ]]; then
  v=$("${OCP_AIRGAP_ROOT}/binaries/openshift-install-fips" version 2>/dev/null | head -1 | awk '{print $2}')
  if [[ "${v}" == "${OCP_VERSION}" ]]; then
    _p "openshift-install-fips present and reports ${v}"
  else
    _f "openshift-install-fips reports '${v}', expected ${OCP_VERSION}"
  fi
else
  _f "openshift-install-fips not extracted -- run ./scripts/70-extract-installer.sh"
fi

# 4 -- cluster resources generated
if [[ -d "${CR}" ]]; then
  [[ -f "${CR}/idms-oc-mirror.yaml" ]] && _p "IDMS generated" || _f "IDMS missing"
  cs=$(find "${CR}" -maxdepth 1 -name 'cs-*.yaml' | wc -l)
  if (( cs > 0 )); then _p "${cs} CatalogSource manifest(s) generated"
  else warn "No CatalogSource manifests (expected if you mirrored no operators)"; fi
  # oc-mirror 4.21 writes signature-configmap.{json,yaml} as files directly in
  # cluster-resources/. Older/upstream docs describe a signatures/ directory.
  # Accept either.
  if compgen -G "${CR}/signature-configmap.*" >/dev/null || [[ -d "${CR}/signatures" ]]; then
    _p "Release signature ConfigMap generated"
  else
    warn "No signature ConfigMap -- release signature verification will not be available"
  fi
else
  _f "No cluster-resources at ${CR}"
fi

# 5 -- operator catalogs are servable, not merely pushed
if command -v python3 >/dev/null 2>&1 && [[ -d "${CR}" ]]; then
  for f in "${CR}"/cs-*.yaml; do
    [[ -e "${f}" ]] || continue
    img=$(python3 -c "
import sys,re
t=open('${f}').read()
m=re.search(r'^\s*image:\s*(\S+)',t,re.M)
print(m.group(1) if m else '')" 2>/dev/null)
    [[ -n "${img}" ]] || continue
    # --filter-by-os is required for manifest lists: without it `oc image
    # info` errors out rather than reporting, which looks like a missing
    # image. Catalog images are commonly multi-arch even when you mirrored
    # a single architecture.
    if run oc image info --registry-config "${MIRROR_PULL_SECRET}" \
         --filter-by-os "linux/${OCP_ARCH:-amd64}" "${img}" >/dev/null 2>&1; then
      _p "Catalog image pullable: ${img##*/}"
    else
      _f "Catalog image NOT pullable: ${img}"
    fi
  done
fi

# 6 -- every operator named in the config actually landed in the catalog
if [[ -f "${IMAGESET_CONFIG}" ]] && command -v python3 >/dev/null 2>&1; then
  mapfile -t want < <(python3 - "${IMAGESET_CONFIG}" <<'PY' 2>/dev/null || true
import sys,re
for l in open(sys.argv[1]):
    m=re.match(r'\s*-\s*name:\s*([a-z0-9][a-z0-9.-]*operator[a-z0-9.-]*|kubevirt-hyperconverged|lvms-operator)\s*$',l)
    if m: print(m.group(1))
PY
)
  if (( ${#want[@]} > 0 )); then
    info "Operators requested in ImageSetConfiguration: ${want[*]}"
    info "  (confirm each appears in the catalog after the cluster exists:"
    info "   oc get packagemanifests -n openshift-marketplace)"
  fi
fi

echo >&2
info "=== ${pass} passed, ${fail} failed ==="
if (( fail > 0 )); then
  die "Mirror verification FAILED. Do not hand off yet. See docs/troubleshooting.md."
fi
ok "Mirror verified. Next: ./scripts/90-handoff.sh"
