#!/usr/bin/env bash
# docs/03-plan-your-content.md -- "Size it before you pull it"
# Run on: CONNECTED bastion
#
# Reports how much disk the mirror will need, by reading the manifest of
# every image the ImageSetConfiguration resolves to and summing the layers
# it would download.
#
# Layers are deduplicated by digest, which is what the cache actually
# stores -- images in a release payload share base layers heavily, so
# counting per-image totals overstates badly.
#
# This reads every manifest rather than sampling. An earlier version
# sampled, and measurements showed that was unusable: container image sizes
# are heavily skewed, and 40-image samples of the same 202-image set
# produced estimates of 32, 40 and 52 GiB on consecutive runs. Reading all
# of them takes a few minutes and gives the same answer every time.

source "$(dirname "$0")/lib/common.sh"
load_env
require_vars MIRROR_OUT RH_PULL_SECRET
require_cmds oc python3

MAP="${MIRROR_OUT}/working-dir/dry-run/mapping.txt"
[[ -f "${MAP}" ]] || die "No dry-run mapping at ${MAP}. Run ./scripts/15-dry-run.sh first."

total=$(wc -l < "${MAP}")
info "Images to inspect: ${total} (reading every manifest; a few minutes)"

python3 - "${MAP}" "${RH_PULL_SECRET}" "linux/${OCP_ARCH:-amd64}" "${ARCHIVE_SIZE_GB:-100}" \
         "${MANIFEST_WORKERS:-8}" <<'PY'
import collections, concurrent.futures, json, subprocess, sys

map_path, auth, osfilter, seg, workers = sys.argv[1:6]
seg, workers = int(seg), int(workers)

# mapping.txt lines are  docker://<source>=docker://<destination>
refs = []
for line in open(map_path):
    line = line.strip()
    if not line:
        continue
    src = line.split("=", 1)[0].strip()
    if src.startswith("docker://"):
        src = src[len("docker://"):]
    if src:
        refs.append(src)
refs = sorted(set(refs))

def layers(ref):
    """Return [(digest, size)] for one image, or None if unreadable."""
    try:
        p = subprocess.run(
            ["oc", "image", "info", "--registry-config", auth,
             "--filter-by-os", osfilter, "-o", "json", ref],
            capture_output=True, timeout=180)
        if p.returncode != 0:
            return None
        d = json.loads(p.stdout)
        return [(l["digest"], int(l["size"])) for l in d.get("layers", [])]
    except Exception:
        return None

uniq, per_image, failed, done = {}, [], [], 0
with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
    for ref, res in zip(refs, ex.map(layers, refs)):
        done += 1
        if sys.stderr.isatty():
            sys.stderr.write(f"\r  read {done}/{len(refs)}")
        if res is None:
            failed.append(ref)
            continue
        per_image.append(sum(s for _, s in res))
        for dg, sz in res:
            uniq[dg] = sz
if sys.stderr.isatty():
    sys.stderr.write("\n")

if not per_image:
    sys.stderr.write("ERROR: could not read any manifests. Check the pull secret "
                     "and connectivity.\n")
    sys.exit(1)

G = 1024 ** 3
dedup = sum(uniq.values()) / G
naive = sum(per_image) / G

print()
print(f"  images read          : {len(per_image)} of {len(refs)}")
if failed:
    print(f"  unreadable           : {len(failed)}  (excluded; estimate is low by that much)")
    for f in failed[:5]:
        print(f"      {f}")
    if len(failed) > 5:
        print(f"      ... and {len(failed)-5} more")
print(f"  unique layers        : {len(uniq):,}")
print(f"  download (dedup)     : {dedup:,.0f} GiB   <- plan against this")
print(f"  sum of all images    : {naive:,.0f} GiB   (ignores shared layers)")
if naive > 0:
    print(f"  shared-layer saving  : {100*(1-dedup/naive):,.0f}%")
print()

def row(label, value, note):
    print(f"    {label:<20} >= {value:>6,.0f} GiB  {note}")

# Multipliers over the deduplicated download, calibrated against a measured
# end-to-end run (202 images, 22.4 GiB deduplicated) and then given ~20%
# margin. Observed ratios are in brackets; see VALIDATION.md.
#
#   cache      [x1.13]  extracted layers plus oc-mirror metadata
#   output     [x1.27]  tar overhead over the cache contents
#   transport  [x1.31]  archive plus binaries and this repo on first transfer
#   imports    [x1.46]  archive PLUS the working-dir that disk-to-mirror
#                       writes at the --from path -- the easiest to underrun
#   registry   [x1.21]  podman volume after the push
M_CACHE, M_OUTPUT, M_TRANSPORT, M_IMPORT, M_REGISTRY = 1.35, 1.50, 1.55, 1.75, 1.45

print("  plan for:")
row("cache dir",          dedup * M_CACHE,     "connected: --cache-dir")
row("output dir",         dedup * M_OUTPUT,    "connected: archives")
row("transport",          dedup * M_TRANSPORT, "removable media (1st run carries binaries)")
row("import dir",         dedup * M_IMPORT,    "disconnected: archive + d2m working-dir")
row("disconnected cache", dedup * M_CACHE,     "archive is extracted here")
row("registry storage",   dedup * M_REGISTRY,  "podman graphroot, NOT --quayRoot")
print()

# What someone provisioning a host actually has to buy: these coexist.
conn = dedup * (M_CACHE + M_OUTPUT)
disc = dedup * (M_IMPORT + M_CACHE + M_REGISTRY)
print("  per host (these live side by side, so add them up):")
print(f"    connected bastion    >= {conn:>6,.0f} GiB   (cache + archives)")
print(f"    disconnected bastion >= {disc:>6,.0f} GiB   (imports + cache + registry)")
print()
print(f"  The disconnected side needs roughly {disc/dedup:.1f}x the download size.")
print("  That is the number most sizing guidance gets wrong.")
print()
print("  'registry storage' is podman's storage root, not --quayRoot:")
print("      df -h \"$(podman info --format '{{.Store.GraphRoot}}')\"")
print("  --quayRoot holds config and certs only (tens of KB).")
print()
print(f"  at archiveSize: {seg} GB -> roughly "
      f"{max(1, int(dedup*M_OUTPUT // seg) + 1)} archive segment(s)")
print()
print("  Multipliers are calibrated from one measured run and padded ~20%.")
print("  Treat as a floor; confirm with df before a long mirror.")
PY

cat >&2 <<'EOF'

The cache and the output directory are separate full-size copies. Putting
both on the same partition means you need roughly double. This is the single
most common reason a mirror fails overnight at 90%.
EOF
