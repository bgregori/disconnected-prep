#!/usr/bin/env bash
# docs/03-plan-your-content.md -- discovering and validating operator content
# Run on: CONNECTED bastion (needs access to the catalog image)
#
#   ./scripts/13-catalog.sh --list            # every package in the catalog
#   ./scripts/13-catalog.sh --list lvm        # ...filtered
#   ./scripts/13-catalog.sh lvms-operator     # channels and versions for one
#   ./scripts/13-catalog.sh --check           # validate your ImageSetConfiguration
#
# Why this exists instead of `oc-mirror list operators`:
#
#   `list`, `describe` and `init` are implemented only in oc-mirror v1, so
#   they require an explicit --v1. On a STIG-hardened host that fails: the
#   v1 path extracts an embedded binary into a temp directory and execs it,
#   and fapolicyd denies execution of anything not in its trust database:
#
#       fork/exec /tmp/oc-mirror-*/oc-mirror: operation not permitted
#
#   Making it work would mean trusting an executable in a user-writable
#   directory, which is precisely what the hardening is there to prevent.
#
#   This script instead reads the catalog's file-based catalog (FBC) with
#   `oc image extract`, using only the already-trusted `oc` binary.
#
# The catalog is extracted once and cached; delete the cache dir to refresh.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars OCP_VERSION RH_PULL_SECRET
require_cmds oc python3

OCP_MINOR="${OCP_MINOR:-${OCP_VERSION%.*}}"
CATALOG="${CATALOG:-registry.redhat.io/redhat/redhat-operator-index:v${OCP_MINOR}}"
FBC_DIR="${FBC_DIR:-${PREP_ROOT:-$HOME/ocp-airgap}/catalog-cache/${OCP_MINOR}}"

# --- fetch the catalog once ------------------------------------------------

if [[ ! -d "${FBC_DIR}" || -z "$(ls -A "${FBC_DIR}" 2>/dev/null)" ]]; then
  info "Extracting catalog ${CATALOG}"
  info "  (a few minutes the first time; cached at ${FBC_DIR})"
  run mkdir -p "${FBC_DIR}"
  # The trailing slash on the source path matters: without it oc extracts
  # nothing and still exits 0.
  run oc image extract "${CATALOG}" \
    --registry-config "${RH_PULL_SECRET}" \
    --filter-by-os "linux/${OCP_ARCH:-amd64}" \
    --path "/configs/:${FBC_DIR}" --confirm
  n=$(find "${FBC_DIR}" -maxdepth 1 -mindepth 1 -type d | wc -l)
  (( n > 0 )) || die "Extracted no packages from ${CATALOG}. Check the pull secret and the catalog tag."
  ok "Cached ${n} packages"
fi

mode="${1:---check}"

case "${mode}" in
  --list)
    filter="${2:-}"
    python3 - "${FBC_DIR}" "${filter}" <<'PY'
import os, sys
d, f = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
pkgs = sorted(p for p in os.listdir(d) if os.path.isdir(os.path.join(d, p)))
hits = [p for p in pkgs if f.lower() in p.lower()] if f else pkgs
for p in hits:
    print(" ", p)
print(f"\n{len(hits)} of {len(pkgs)} packages" + (f" matching '{f}'" if f else ""))
PY
    ;;

  --check)
    [[ -f "${IMAGESET_CONFIG}" ]] \
      || die "No ImageSetConfiguration at ${IMAGESET_CONFIG}. Build one first (docs/03)."
    info "Validating ${IMAGESET_CONFIG} against ${CATALOG}"
    python3 - "${FBC_DIR}" "${IMAGESET_CONFIG}" <<'PY'
import json, os, re, sys
fbc, cfg = sys.argv[1], sys.argv[2]

def channels(pkg):
    f = os.path.join(fbc, pkg, "catalog.json")
    if not os.path.exists(f):
        return None, None
    buf = open(f).read(); dec = json.JSONDecoder(); i = 0; ch = []; default = None
    while i < len(buf):
        while i < len(buf) and buf[i] in " \n\r\t":
            i += 1
        if i >= len(buf):
            break
        o, i = dec.raw_decode(buf, i)
        if o.get("schema") == "olm.package":
            default = o.get("defaultChannel")
        elif o.get("schema") == "olm.channel":
            ch.append(o["name"])
    return default, sorted(set(ch))

# Pull (package, [channels]) out of the operators section. PyYAML when
# available; otherwise an indentation-aware fallback, because a disconnected
# bastion may not have python3-pyyaml.
wanted = []
try:
    import yaml
    doc = yaml.safe_load(open(cfg)) or {}
    for cat in (doc.get("mirror", {}) or {}).get("operators", []) or []:
        for p in cat.get("packages", []) or []:
            wanted.append((p.get("name"),
                           [c.get("name") for c in (p.get("channels") or [])]))
except ImportError:
    pkg = None; in_ch = False
    for raw in open(cfg):
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^-\s*name:\s*(\S+)", s)
        if m and not in_ch:
            pkg = (m.group(1), []); wanted.append(pkg); continue
        if s.startswith("channels:"):
            in_ch = True; continue
        if m and in_ch and pkg:
            pkg[1].append(m.group(1)); in_ch = False

wanted = [(n, c) for n, c in wanted if n]
if not wanted:
    print("  No operator packages found in the configuration.")
    sys.exit(0)

bad = 0
print(f"\n  {'package':<34}{'channel':<16}verdict")
print("  " + "-" * 76)
for name, chans in wanted:
    default, have = channels(name)
    if have is None:
        print(f"  {name:<34}{'':<16}PACKAGE NOT IN CATALOG"); bad += 1
        continue
    if not chans:
        print(f"  {name:<34}{'(none given)':<16}OK -- defaults to {default}")
        continue
    for c in chans:
        if c in have:
            note = "" if c == default else f"  (catalog default: {default})"
            print(f"  {name:<34}{c:<16}OK{note}")
        else:
            print(f"  {name:<34}{c:<16}NO SUCH CHANNEL -> {have}"); bad += 1

print()
if bad:
    print(f"  {bad} problem(s). Fix these before mirroring -- oc-mirror reports")
    print("  them only as 'no related images found', without naming the package.")
    sys.exit(1)
print("  All packages and channels resolve against the catalog.")
PY
    ;;

  --help|-h)
    sed -n '3,20p' "$0" | sed 's/^# \?//'
    ;;

  *)
    pkg="${mode}"
    python3 - "${FBC_DIR}" "${pkg}" <<'PY'
import json, os, sys
fbc, pkg = sys.argv[1], sys.argv[2]
f = os.path.join(fbc, pkg, "catalog.json")
if not os.path.exists(f):
    cands = [p for p in sorted(os.listdir(fbc)) if pkg.lower() in p.lower()]
    print(f"  No package named '{pkg}' in the catalog.")
    if cands:
        print("  Did you mean:")
        for c in cands[:10]:
            print("   ", c)
    sys.exit(1)
buf = open(f).read(); dec = json.JSONDecoder(); i = 0
default = None; chans = {}
while i < len(buf):
    while i < len(buf) and buf[i] in " \n\r\t":
        i += 1
    if i >= len(buf):
        break
    o, i = dec.raw_decode(buf, i)
    if o.get("schema") == "olm.package":
        default = o.get("defaultChannel")
    elif o.get("schema") == "olm.channel":
        chans[o["name"]] = [e["name"] for e in o.get("entries", [])]
print(f"\n  package: {pkg}")
print(f"  default channel: {default}\n")
for name in sorted(chans):
    mark = "  <- default" if name == default else ""
    print(f"  channel: {name}{mark}")
    for e in sorted(chans[name])[-6:]:
        print(f"      {e}")
    if len(chans[name]) > 6:
        print(f"      ... {len(chans[name])} versions total")
    print()
print("  Use the channel name in your ImageSetConfiguration, not the version.")
PY
    ;;
esac
