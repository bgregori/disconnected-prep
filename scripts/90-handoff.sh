#!/usr/bin/env bash
# docs/09-handoff.md
# Run on: REGISTRY HOST
#
# Assembles everything the install side needs into one directory, including
# ready-to-paste install-config.yaml fragments. Prep is finished when this
# directory exists and scripts/80-verify-mirror.sh passes.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars PREP_ROOT IMPORTS_DIR EXPORT_TAG REGISTRY_HOST REGISTRY_PORT QUAY_ROOT OCP_VERSION MIRROR_PULL_SECRET

OUT="${PREP_ROOT}/handoff/${EXPORT_TAG}"
CR="${IMPORTS_DIR}/${EXPORT_TAG}/working-dir/cluster-resources"
[[ -d "${CR}" ]] || die "No cluster-resources at ${CR}. Run ./scripts/60-push-to-registry.sh."

run mkdir -p "${OUT}/cluster-resources" "${OUT}/bin" "${OUT}/certs"

info "Collecting artifacts"
run cp -r "${CR}/." "${OUT}/cluster-resources/"
run cp "${QUAY_ROOT}/quay-rootCA/rootCA.pem" "${OUT}/certs/"
run cp "${MIRROR_PULL_SECRET}" "${OUT}/pull-secret.json"
run chmod 600 "${OUT}/pull-secret.json"
# openshift-install-fips is extracted into binaries/; oc is normally on PATH
# in /usr/local/bin. Look in both places so the bundle is complete either way.
for b in openshift-install-fips oc; do
  if [[ -f "${PREP_ROOT}/binaries/${b}" ]]; then
    run cp "${PREP_ROOT}/binaries/${b}" "${OUT}/bin/"
  elif src=$(command -v "${b}" 2>/dev/null); then
    run cp "${src}" "${OUT}/bin/"
  else
    warn "${b} not found -- the install side will need to obtain it separately."
  fi
done
# The ImageSetConfiguration is part of the handoff contract -- it is the only
# record of what this environment can install, and it is required for every
# Day-2 update. On the registry host it usually arrives with the archive
# rather than living in config/, so check both.
if [[ -f "${IMAGESET_CONFIG}" ]]; then
  run cp "${IMAGESET_CONFIG}" "${OUT}/imageset-config.yaml"
elif [[ -f "${IMPORTS_DIR}/${EXPORT_TAG}/imageset-config.yaml" ]]; then
  run cp "${IMPORTS_DIR}/${EXPORT_TAG}/imageset-config.yaml" "${OUT}/imageset-config.yaml"
else
  warn "No ImageSetConfiguration found -- Day-2 updates will have no baseline."
fi

# --- install-config.yaml fragments ----------------------------------------
# These are the parts of install-config.yaml that are determined by prep.
# Everything else (topology, networking, hardware) belongs to the install side.

info "Generating install-config.yaml fragments"

# imageDigestSources: derived from the IDMS. Without this the agent ISO tries
# to reach quay.io during bootstrap and the install hangs.
python3 - "${CR}/idms-oc-mirror.yaml" > "${OUT}/install-config-fragment.yaml" <<'PY'
import re, sys

# oc-mirror 4.21 emits entries as `- mirrors:` first, then `source:`; other
# tooling emits the reverse, and the file holds several YAML documents.
# Handle both orders, and never emit a silently empty block -- a blank
# imageDigestSources is what makes a disconnected bootstrap hang.

def parse_with_yaml(text):
    import yaml
    out = []
    for doc in yaml.safe_load_all(text):
        if not doc or doc.get("kind") != "ImageDigestMirrorSet":
            continue
        for e in (doc.get("spec", {}) or {}).get("imageDigestMirrors", []) or []:
            if e.get("source"):
                out.append((e["source"], list(e.get("mirrors") or [])))
    return out

def parse_by_hand(text):
    out, entry, in_mirrors = [], None, False
    base = entry_indent = None

    def flush():
        nonlocal entry
        if entry and entry[0]:
            out.append((entry[0], entry[1]))
        entry = None

    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw.strip() == "---":
            flush(); in_mirrors = False; base = entry_indent = None
            continue
        indent, s = len(raw) - len(raw.lstrip()), raw.strip()
        if re.match(r"^imageDigestMirrors:\s*$", s):
            flush(); base = indent; entry_indent = None; in_mirrors = False
            continue
        if base is None:
            continue
        if indent <= base and not s.startswith("-"):
            flush(); base = entry_indent = None; in_mirrors = False
            continue
        item = re.match(r"^-\s*(.*)$", s)
        # Mirror values are also "- " items but sit deeper than the entries,
        # so pin the entry indent from the first one and compare exactly.
        if item and entry_indent is None and indent >= base:
            entry_indent = indent
        if item and indent == entry_indent:
            flush(); entry = [None, []]; in_mirrors = False
            rest = item.group(1).strip()
            if rest.startswith("source:"):
                entry[0] = rest.split("source:", 1)[1].strip()
            elif rest.startswith("mirrors:"):
                in_mirrors = True
            continue
        if entry is None:
            continue
        if s.startswith("source:"):
            entry[0] = s.split("source:", 1)[1].strip(); in_mirrors = False
        elif s.startswith("mirrors:"):
            in_mirrors = True
        elif in_mirrors and item:
            val = item.group(1).strip()
            if val:
                entry[1].append(val)
    flush()
    return out

text = open(sys.argv[1]).read()
pairs = []
try:
    pairs = parse_with_yaml(text)
except Exception:
    pass
if not pairs:
    pairs = parse_by_hand(text)

if not pairs:
    sys.stderr.write(
        "ERROR: parsed no imageDigestMirrors from the IDMS.\n"
        "       Refusing to emit an empty imageDigestSources block -- that\n"
        "       would make the disconnected install hang at bootstrap.\n"
        "       Transcribe " + sys.argv[1] + " into install-config.yaml by hand.\n")
    sys.exit(1)

missing = [s for s, m in pairs if not m]
if missing:
    sys.stderr.write("ERROR: these sources parsed with no mirrors: %s\n" % ", ".join(missing))
    sys.exit(1)

print("# Paste into install-config.yaml. Generated by scripts/90-handoff.sh.")
print("# Required for a disconnected install: without it the bootstrap tries")
print("# to pull from the internet and the install hangs.")
print("#")
print(f"# Derived from {sys.argv[1]} ({len(pairs)} mirror entries).")
print("imageDigestSources:")
for source, mirrors in pairs:
    print(f"  - source: {source}")
    print("    mirrors:")
    for mi in mirrors:
        print(f"      - {mi}")
PY

{
  echo ""
  echo "# --- additionalTrustBundle ---"
  echo "# The Quay CA. Required so the cluster trusts the mirror registry."
  echo "additionalTrustBundle: |"
  sed 's/^/  /' "${QUAY_ROOT}/quay-rootCA/rootCA.pem"
  echo "additionalTrustBundlePolicy: Always"
  echo ""
  echo "# --- pullSecret ---"
  echo "# Single-quoted contents of pull-secret.json in this directory."
  echo "# pullSecret: '<contents of pull-secret.json>'"
} >> "${OUT}/install-config-fragment.yaml"

# --- manifest --------------------------------------------------------------

cat > "${OUT}/README.md" <<EOF
# Handoff bundle -- ${EXPORT_TAG}

Produced by \`disconnected-prep\` on $(date -u +%Y-%m-%dT%H:%M:%SZ) by ${USER}@$(hostname -f 2>/dev/null || hostname).

## Mirror registry

| | |
|---|---|
| Endpoint | \`https://$(registry_ref)\` |
| OCP version | \`${OCP_VERSION}\` |
| Release payload | \`$(registry_ref)/openshift/release-images:${OCP_VERSION}-${RELEASE_ARCH:-x86_64}\` |
| Architecture | \`${OCP_ARCH:-amd64}\` |

## Contents

| Path | Use |
|---|---|
| \`install-config-fragment.yaml\` | Paste \`imageDigestSources\` + \`additionalTrustBundle\` into install-config.yaml |
| \`pull-secret.json\` | The \`pullSecret\` value for install-config.yaml |
| \`certs/rootCA.pem\` | Quay CA, also needed by any host pulling from the mirror |
| \`cluster-resources/\` | Apply **after** install completes |
| \`bin/openshift-install-fips\` | Use this, not the generic installer, when \`fips: true\` |
| \`bin/oc\` | Version-matched client |
| \`imageset-config.yaml\` | What was mirrored; needed for Day-2 updates |

## Before you install

\`\`\`yaml
# install-config.yaml must contain all three or the install will fail closed:
fips: true
imageDigestSources: [...]      # from install-config-fragment.yaml
additionalTrustBundle: |       # from install-config-fragment.yaml
\`\`\`

The registry hostname \`${REGISTRY_HOST}\` must resolve **from the cluster
nodes**, not only from the registry host. Verify before generating the ISO.

## After you install

\`\`\`sh
oc apply -f cluster-resources/
oc patch operatorhub cluster --type merge \\
  -p '{"spec":{"disableAllDefaultSources":true}}'
\`\`\`

Applying IDMS/ITMS triggers a rolling restart of every node as the machine
config operator updates the CRI-O configuration. On a single-node cluster
that is a full outage; expect the API to disappear for several minutes.

## Known limits of this mirror

- Only \`${OCP_ARCH:-amd64}\` was mirrored.
- Only version \`${OCP_VERSION}\`. Upgrades need another prep cycle --
  see \`docs/10-day2-delta.md\`.
- Operators not in \`imageset-config.yaml\` are not installable. Adding one
  means another trip across the airgap.
- CDI/DataVolume imports do **not** honour IDMS/ITMS. If you are using
  OpenShift Virtualization boot sources, point DataVolumes at
  \`$(registry_ref)\` explicitly. See \`docs/03-plan-your-content.md\`.
EOF

info "Generating checksums"
run_sh "cd '${OUT}' && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS"

echo >&2
ok "Handoff bundle ready: ${OUT}"
du -sh "${OUT}" >&2
echo >&2
info "Review ${OUT}/README.md, then work through checklists/handoff-contract.md"
