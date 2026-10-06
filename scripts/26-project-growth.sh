#!/usr/bin/env bash
# docs/11-capacity-planning.md
# Run on: either host (it does no I/O against a registry)
#
# Projects multi-year disk growth for the mirror registry and the two
# oc-mirror caches, so a customer can size against their own retention
# policy rather than a generic number.
#
#   ./scripts/26-project-growth.sh
#   VERSIONS_PER_YEAR=4 YEARS=5 RETAIN=3 ./scripts/26-project-growth.sh
#
# Defaults are the measured values from VALIDATION.md. Override any of them
# if you have better numbers for your own content set -- in particular
# raise GIB_PER_VERSION if you mirror virtualization guest images, which
# are large and entirely under your control.

source "$(dirname "$0")/lib/common.sh"
[[ -f "${REPO_ROOT}/config/prep.env" ]] && load_env

# --- inputs ----------------------------------------------------------------

# Measured: one OCP 4.21.34 amd64 payload, deduplicated.
GIB_PER_VERSION="${GIB_PER_VERSION:-19}"
# Measured: a second consecutive z-stream cost 87% of a standalone payload.
MARGINAL_FRACTION="${MARGINAL_FRACTION:-0.87}"
# Operator content refreshed when the catalog version changes.
GIB_OPERATORS="${GIB_OPERATORS:-6}"
# New platform versions mirrored per year.
VERSIONS_PER_YEAR="${VERSIONS_PER_YEAR:-4}"
# Operator catalog refreshes per year.
CATALOG_REFRESH_PER_YEAR="${CATALOG_REFRESH_PER_YEAR:-1}"
# Versions kept on disk. 0 = never prune.
RETAIN="${RETAIN:-0}"
YEARS="${YEARS:-5}"

python3 - "${GIB_PER_VERSION}" "${MARGINAL_FRACTION}" "${GIB_OPERATORS}" \
         "${VERSIONS_PER_YEAR}" "${CATALOG_REFRESH_PER_YEAR}" \
         "${RETAIN}" "${YEARS}" <<'PY'
import sys
base, frac, ops, per_yr, refresh, retain, years = (
    float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]),
    float(sys.argv[4]), float(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))

marginal = base * frac

print()
print("  assumptions")
print(f"    first version                 {base:,.0f} GiB")
print(f"    each additional version       {marginal:,.0f} GiB  ({frac:.0%} of a full payload)")
print(f"    operator set per catalog      {ops:,.0f} GiB")
print(f"    new versions per year         {per_yr:,.0f}")
print(f"    catalog refreshes per year    {refresh:,.0f}")
print(f"    versions retained             {'all (never pruned)' if retain == 0 else retain}")
print()

hdr = f"  {'year':>4} {'versions':>9} {'registry':>10} {'each cache':>11} {'all three':>10}"
print(hdr); print("  " + "-" * (len(hdr) - 2))

for y in range(1, years + 1):
    mirrored = 1 + per_yr * y
    held = mirrored if retain == 0 else min(mirrored, retain)
    registry = base + marginal * (held - 1) + ops * (1 + refresh * y if retain == 0 else 1)
    # Caches track the registry but lack the registry's own metadata overhead.
    cache = registry * 0.9
    total = registry + 2 * cache
    print(f"  {y:>4} {held:>9,.0f} {registry:>8,.0f} GiB {cache:>9,.0f} GiB {total:>8,.0f} GiB")

# Provisioning recommendation, as distinct from the projection.
final_held = (1 + per_yr * years) if retain == 0 else min(1 + per_yr * years, retain)
final_reg = base + marginal * (final_held - 1) + ops * (
    1 + refresh * years if retain == 0 else 1)

print()
if retain == 0:
    print("  Nothing is pruned here, so growth is unbounded. Provision for the")
    print(f"  year-{years} figure and plan a retention policy anyway:")
    print("      RETAIN=3 ./scripts/26-project-growth.sh")
    rec_reg, rec_cache = final_reg * 1.25, final_reg * 0.9 * 1.25
    why = f"year-{years} projection + 25%"
else:
    print(f"  Bounded at {retain} retained versions, so the steady state is flat.")
    print("  Do not provision exactly to it. Pruning requires `oc-mirror delete`")
    print("  to actually be run, and Quay only releases the space after its")
    print("  time-machine window (2 weeks by default). Between a mirror and a")
    print("  successful prune you transiently hold MORE than the steady state.")
    # One extra version in flight, plus slack for a prune cycle that slips.
    rec_reg = (final_reg + marginal) * 1.3
    rec_cache = rec_reg * 0.9
    why = "steady state + 1 version in flight + 30%"

print()
print(f"  recommended provisioning  ({why})")
print(f"    registry storage        >= {rec_reg:>6,.0f} GiB   registry host (podman graphroot)")
print(f"    cache, connected        >= {rec_cache:>6,.0f} GiB")
print(f"    cache, registry host    >= {rec_cache:>6,.0f} GiB")
print(f"    imports / exports       >= {base*1.6:>6,.0f} GiB   each side, transient")
print()
print(f"    volume group, min size  >= {(rec_reg + rec_cache)*1.4:>6,.0f} GiB   leave ~40% unallocated")
print()
print("  'all three' = registry + the oc-mirror cache on BOTH hosts.")
print("  Add ~1 archive per side for imports/exports (transient).")
print("  Provision on LVM and leave free extents -- see docs/11-capacity-planning.md")
print()
PY
