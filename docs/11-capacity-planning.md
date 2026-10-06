# Capacity planning for the long term

Sizing for day one is [01-prerequisites.md](01-prerequisites.md). This
chapter is about year three.

A disconnected mirror registry is not a cache — nothing expires, nothing is
evicted, and nothing shrinks on its own. Every OpenShift version and every
operator you ever mirror stays on disk until someone deliberately removes
it. Most disconnected registries are not sized for that, and the failure
shows up as a full filesystem during an upgrade, which is the worst possible
moment.

## The short answer: 500 GB, on the right mount, with a retention policy

**500 GB on the registry host is the right default.** The measurements below
support it comfortably. Two conditions have to hold, and both are things
people get wrong far more often than they get the number wrong:

1. **The 500 GB has to be where podman actually stores images** — not where
   `--quayRoot` points. See [below](#the-number-is-not-the-usual-failure).
2. **Somebody has to retire old versions.** 500 GB is generous for any
   bounded retention policy and insufficient for none.

Supporting data — registry host total, meaning registry storage **plus** the
oc-mirror cache **plus** one import archive, all of which live on that host:

| Scenario | Versions held | Host total | of 500 GB |
|---|---|---|---|
| Platform + a few operators | 3 | 153 GiB | 33% |
| + virtualization & guest images | 3 | 189 GiB | 40% |
| Platform + a few operators | 5 | 223 GiB | 48% |
| + virtualization & guest images | 5 | 259 GiB | 56% |
| **Never pruned**, quarterly, 3 years | 13 | **506 GiB** | **109%** |
| **Never pruned**, quarterly, 5 years | 21 | **789 GiB** | **169%** |

So: comfortable for every bounded policy tested, with room left over for
other uses of the box — and it runs out in **year three** if nobody ever
retires anything.

That makes the useful sentence to a customer not "you need 500 GB" but:

> 500 GB, and decide now how many OpenShift versions you keep. Three is a
> good default: current, target, and one to roll back to.

The rest of this chapter is for the cases where that is not enough —
unusually large content sets, retention mandated by policy, or a customer
who wants the growth modelled rather than asserted.

### The number is not the usual failure

Three things break capacity more often than under-sizing:

- **The disk is mounted in the wrong place.** `--quayRoot` holds config and
  certs — 32 KB measured. Images go to podman's storage root, usually under
  `$HOME`. Provision 500 GB at `/data`, point `--quayRoot` there, and the
  images still land on the root filesystem. This happened on the reference
  environment: a 500 GB volume sat at 5% used while `/` absorbed everything.
- **Nothing ever gets deleted**, because nobody was told it had to be.
- **Reclamation is assumed to be immediate.** It takes two weeks.

### The rest in brief

- **Platform versions dominate growth.** Each additional z-stream costs
  roughly a *full* payload — measured at **+18.6 GiB**, 87% of a standalone
  one. Adjacent z-streams share far less than people assume.
- **Three filesystems grow monotonically**: the registry's storage, and the
  oc-mirror cache on *each* bastion. The connected bastion needs its own
  comparable allowance, which a "500 GB on the registry host" rule does not
  cover.
- **Put them on LVM.** You will need to extend something, and you cannot
  take this registry down to repartition once a cluster depends on it.
- **Plan the pruning process on day one.** `oc-mirror delete` exists, but it
  is two-stage, needs the original workspace, and Quay does not return the
  space for two weeks.

---

## What grows, and how fast

Ranked by how much attention each needs.

| # | Location | Host | Growth | Shrinks? |
|---|---|---|---|---|
| 1 | Registry storage (podman graphroot) | registry | every version + operator, forever | only via `oc-mirror delete` + Quay GC, 2-week lag |
| 2 | `CACHE_DIR` | **both** | same rate as the registry | only manually, or `--force-cache-delete` |
| 3 | `IMPORTS_DIR` | registry | one archive per run | trivially — just delete old ones |
| 4 | `EXPORTS_DIR` | connected | one archive per run | trivially |
| 5 | `MIRROR_OUT` | connected | bounded: one archive + history | self-managing |

Two things people get wrong here:

**The caches are not scratch space.** `--cache-dir` holds the full
uncompressed layer set and grows exactly as the registry does — on *both*
hosts. Over three years you are provisioning that capacity three times.
It is tempting to treat the cache as disposable, but deleting it means the
next "small delta update" re-downloads everything.

**`MIRROR_OUT` is the one thing that does not grow.** oc-mirror deletes the
previous `mirror_*.tar` before each run, so it holds one archive plus the
`.history/` files (~130 KB per run). Do not over-provision it, and do not
delete `.history/` to save space —
[that is what makes deltas work](10-day2-delta.md).

---

## Measured marginal costs

From a real mirror on RHEL 9.6, deduplicated by layer digest. Deduplication
matters: counting per-image overstates by ~37%.

| Content | Total | Marginal |
|---|---|---|
| OCP 4.21.34 platform, amd64 | 21.3 GiB | — |
| + a second z-stream (4.21.33) | 39.9 GiB | **+18.6 GiB** |
| + virtualization (CNV) operator | 25.9 GiB | **+4.6 GiB** |
| + compliance + file-integrity + 3 diagnostic images | 22.4 GiB | **+1.1 GiB** |

### Why a second z-stream costs nearly a full payload

Consecutive z-streams reused only **33% of layers**, and the reused ones
were the small ones — 87% of the *bytes* were new. Release payload images
are rebuilt wholesale between z-streams, so the usual intuition about
container layer sharing does not apply.

> **Planning rule: budget ~19 GiB per retained OpenShift version**,
> ~20–25 GiB for a minor version bump (new payload plus a new operator
> catalog). Operators are comparatively cheap — single-digit GiB each — and
> guest images for virtualization are a separate, potentially large line
> item you control directly.

---

## Projecting multi-year growth

Growth is driven by **how many versions you retain**, not how often you
mirror. Re-mirroring the same version costs nothing; retaining an extra one
costs ~19 GiB in the registry and ~19 GiB in *each* cache.

```
registry growth/year ≈ (versions retained per year × 19 GiB)
                     + (operator catalog refreshes × 5–10 GiB)
```

Worked profiles, assuming nothing is ever pruned:

| Profile | Cadence | Registry yr 1 | yr 3 | yr 5 |
|---|---|---|---|---|
| **Minimal** — platform only, 2 updates/yr | 2 × 19 | 60 GiB | 136 GiB | 212 GiB |
| **Typical** — platform + 3–4 operators, quarterly | 4 × 19 + 6 | 104 GiB | 268 GiB | 432 GiB |
| **Heavy** — + virtualization & guest images, quarterly | 4 × 19 + 15 | 140 GiB | 380 GiB | 620 GiB |

Then, because the caches track the registry:

| Profile | Registry yr 3 | Each cache yr 3 | **Total across all three** |
|---|---|---|---|
| Minimal | 136 GiB | ~120 GiB | **~376 GiB** |
| Typical | 268 GiB | ~240 GiB | **~748 GiB** |
| Heavy | 380 GiB | ~340 GiB | **~1.06 TiB** |

Add transient space for imports/exports (one archive each, 30–60 GiB).

> These are the **unpruned** curves, and they are the argument for a
> retention policy rather than for a bigger disk. With retention bounded at
> three versions the registry host sits at ~153 GiB indefinitely and 500 GB
> never becomes the problem. Without it, no plausible initial allocation
> lasts five years.

Run the model against a customer's own policy rather than reading off this
table:

```sh
RETAIN=3 ./scripts/26-project-growth.sh
GIB_OPERATORS=25 RETAIN=5 YEARS=7 ./scripts/26-project-growth.sh
```

---

## Provision for extension, not for a guess

You will get the forecast wrong. Design so that being wrong is cheap.

At 500 GB with bounded retention you will probably never need to extend
anything. Use LVM anyway — it costs nothing on day one, and it converts the
case where you *were* wrong from an outage and a change request into a
two-second online operation. Repartitioning a registry a production cluster
depends on is not something you want to discover you need.

```sh
# Registry host: dedicated VG for registry storage
sudo pvcreate /dev/nvme1n1
sudo vgcreate vg_registry /dev/nvme1n1
sudo lvcreate -L 500G -n lv_quay vg_registry
sudo mkfs.xfs /dev/vg_registry/lv_quay

sudo mkdir -p /var/lib/registry-storage
echo '/dev/vg_registry/lv_quay /var/lib/registry-storage xfs defaults 0 2' \
  | sudo tee -a /etc/fstab
sudo mount -a
```

Then point podman at it **before installing Quay** — remember `--quayRoot`
does *not* control where images go:

```sh
mkdir -p ~/.config/containers
cat > ~/.config/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
graphroot = "/var/lib/registry-storage/containers"
EOF
podman info --format '{{.Store.GraphRoot}}'    # confirm before installing
```

Extending later:

```sh
sudo lvextend -L +250G /dev/vg_registry/lv_quay
sudo xfs_growfs /var/lib/registry-storage      # online, no downtime
```

**Leave unallocated space in the volume group.** Allocate perhaps 60% of the
VG initially. Free extents in the VG are the cheapest insurance available —
you can grow whichever filesystem actually turns out to need it.

**Use XFS.** It grows online; ext4 can too, but XFS is the RHEL default and
handles large files better.

---

## Reclaiming space

### Deleting mirrored content

`oc-mirror delete` is two-stage and uses a separate `DeleteImageSetConfiguration`
so you cannot accidentally delete everything by editing the wrong file.

```sh
cat > delete-isc.yaml <<'EOF'
apiVersion: mirror.openshift.io/v1alpha2
kind: DeleteImageSetConfiguration
delete:
  platform:
    channels:
      - name: stable-4.21
        minVersion: 4.21.26
        maxVersion: 4.21.26
EOF

# Stage 1 -- generate and REVIEW the delete plan
oc-mirror delete --v2 --config delete-isc.yaml \
  --workspace file:///home/user/ocp-airgap/mirror-out \
  --generate --delete-id retire-4.21.26 \
  docker://registry.example.com:8443

# Stage 2 -- execute, after reading the generated file
oc-mirror delete --v2 \
  --delete-yaml-file /home/user/ocp-airgap/mirror-out/working-dir/delete/delete-images-retire-4.21.26.yaml \
  --force-cache-delete true \
  docker://registry.example.com:8443
```

Three things to know before you rely on this:

- **Review stage 1's output.** It lists exactly what will go. This is the
  only safety net.
- **`--force-cache-delete true` is required** to reclaim the cache as well.
  Without it you free registry space and the cache keeps growing.
- **It needs the original workspace.** Another reason to retain
  `mirror-out/working-dir/`.

### Quay does not free space immediately

Quay keeps deleted and overwritten tags recoverable for its time-machine
window — `DEFAULT_TAG_EXPIRATION`, **2 weeks** by default. Blobs become
garbage-collectable only after that.

So: **disk does not come back for two weeks.** Do not schedule a delete as a
remedy for a filesystem that is full today. Prune on a cadence, ahead of
need.

For a disconnected mirror that is never rolled back, shortening the window
is reasonable:

```yaml
# /data/quay/quay-config/config.yaml
DEFAULT_TAG_EXPIRATION: 1d
```

Restart Quay afterwards. Verify reclamation actually happens — measure, do
not assume:

```sh
df -h "$(podman info --format '{{.Store.GraphRoot}}')"
```

### Pruning imports and exports

The easy win, and worth automating from day one:

```sh
# keep the two most recent transfers on each side
ls -1dt ~/ocp-airgap/imports/*/ | tail -n +3 | xargs -r rm -rf
ls -1dt ~/ocp-airgap/exports/*/ | tail -n +3 | xargs -r rm -rf
```

Keep at least one, so a failed push can be retried without re-crossing the
airgap.

---

## Monitoring

Three filesystems, on two hosts. Alert on all of them.

| Watch | Threshold | Because |
|---|---|---|
| registry storage | 70% warn / 85% critical | reclamation takes 2 weeks |
| `CACHE_DIR`, both hosts | 75% / 90% | a full cache fails the next mirror |
| imports/exports | 80% | usually just needs pruning |
| VG free extents | < 20% unallocated | you are out of cheap options |

85% critical on the registry looks conservative. It is not: at 85% you have
roughly one update cycle of headroom, and if reclamation is the answer it
takes a fortnight.

```sh
# cheap check, suitable for cron on both hosts
for p in "$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)" \
         /data/cache ~/ocp-airgap/imports; do
  [ -d "$p" ] || continue
  u=$(df -P "$p" | tail -1 | awk '{print $5}' | tr -d '%')
  [ "$u" -ge 80 ] && echo "WARN ${p} at ${u}%"
done
```

Also record the size after every mirroring run — a trend line tells you when
you will run out, which a single reading never does. Append to a CSV and
keep it with the `imageset-config.yaml`.

---

## Operating cadence

**Every mirroring run** — record registry size and cache size into your
trend log:

```sh
date +%F,$(du -sb "$(podman info --format '{{.Store.GraphRoot}}')" | cut -f1),$(du -sb /data/cache | cut -f1)
```

**Quarterly** — prune imports/exports; review the version list against
what the cluster is actually running; check trend against capacity.

**Annually, or at each minor version adoption** — retire z-streams nobody
will roll back to, using `oc-mirror delete`. Verify the space returned after
the time-machine window. Re-forecast.

### Which versions to retain

A defensible default:

- the version currently running
- the version you are upgrading to
- **one** prior version, for rollback
- retire everything older

Three versions is roughly 60 GiB of platform content and bounds growth to
replacement rather than accumulation. If policy requires retaining every
version ever deployed, say so explicitly in the capacity plan and size for
~19 GiB per year per retained version — that is an accreditation decision
with a disk-shaped cost, and it is better surfaced at design time than
discovered in year four.

---

## Handing this to a customer

### What to actually say

> **500 GB on the registry host.** That covers the registry, the oc-mirror
> cache and an import archive, with headroom for other use of the box.
>
> **Don't forget the connected bastion** — it needs a comparable allowance
> for its own cache and archive staging. Budget 300–500 GB there too; it is
> the half that gets forgotten, because the registry is the thing people
> think about.
>
> **Decide how many OpenShift versions you keep.** Three is a good default:
> current, target, and one to roll back to. That is the decision that makes
> 500 GB last; without it, nothing does.

### The points that get missed

1. **The registry is production infrastructure.** If it fills or fails, the
   cluster cannot pull images — including during recovery.
2. **Nothing expires.** It is not a cache, and there is no automatic
   cleanup. Someone has to run `oc-mirror delete`.
3. **Reclamation has a two-week lag.** Prune on a schedule, not in response
   to an alert.
4. **Verify the disk is where podman stores**, not where `--quayRoot`
   points. Cheap to check, expensive to discover later:
   ```sh
   df -h "$(podman info --format '{{.Store.GraphRoot}}')"
   ```
5. **Budget ~19 GiB per retained OpenShift version**, in the registry and in
   each of the two caches.
6. **LVM with free extents** makes a wrong forecast survivable. Not
   essential at 500 GB with bounded retention, but it costs nothing to set
   up on day one and converts a future outage into a two-second
   `lvextend`.
7. **Capacity is a retention-policy question.** How many versions must be
   kept, and for how long, is the input that determines the number — and in
   an accredited environment that may be someone else's decision to make.
