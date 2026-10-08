# Day-2 delta updates

Adding a z-stream upgrade or a new operator to an existing disconnected
environment.

This is the same pipeline as the initial run, with one thing that must be
right: **reuse the persistent state**. Done correctly, a z-stream bump
transfers tens of gigabytes instead of hundreds.

---

## How incremental mirroring actually works

`oc-mirror` keeps a history of what it has already archived at
`<destination>/working-dir/.history/`. On a run against the **same**
destination it compares against that history and writes only new blobs.

Two consequences that are easy to get backwards:

> **A new output directory produces a full archive.** No history means no
> baseline. Dated per-run output directories — a pattern that looks tidy and
> appears in several published guides — silently defeat incremental
> mirroring entirely.

> **`oc-mirror` deletes existing `mirror_*.tar` from the destination before
> each run.** Archives you have not yet transferred will be gone. This repo
> stages copies into `exports/<tag>/` after every run for exactly this
> reason.

The layer cache (`--cache-dir`) is a separate mechanism: it avoids
re-downloading from upstream. The history controls what goes into the
archive. You want both preserved.

### Measured

Verified on RHEL 9.6 with `oc-mirror` 4.21, mirroring two UBI images:

| Run | Destination | Cache | Archive |
|---|---|---|---|
| 1 | `mirror-out` — no history | cold | **186 M** |
| 2 | `mirror-out` — history present | warm | **649 K** |
| 3 | fresh directory | **warm** | **186 M** |

Run 3 is the one that matters. The cache was warm, so almost nothing was
downloaded and the run was quick — but the archive was full size again,
because the new destination had no history. A warm cache makes a re-mirror
*fast*; only the history makes the resulting archive *small*.

If you transfer archives across an airgap, the archive size is what you
actually care about.

---

### Measured on a real delta

Adding one operator (GitOps) to an existing 202-image mirror:

| | Initial mirror | Delta |
|---|---|---|
| Archive | 29 GB | **9.1 GB** |
| Mirror wall clock | 14m53s | 6m16s |
| Transfer | binaries + repo + archive | archive only |

9.1 GB is larger than "one operator" sounds, because the GitOps `latest`
channel carries many bundle versions and the Argo CD images are sizeable.
The saving is real but it is proportional to what actually changed — do not
promise a customer that every delta is small.

> Working without this repo? Skip to
> [the whole cycle by hand](#the-whole-cycle-by-hand) — the same six
> commands, written out.

## Connected bastion

### 1. Update the configuration

For a z-stream upgrade, two things change: the version you are mirroring
and the tag that identifies this run. By hand, the version goes into the
ImageSetConfiguration you edit below, and the tag is the export directory
you create — `2026-12-01_z-stream-4.21.28` in the examples that follow.
Dating the tag and naming its purpose is what makes the export directory
self-describing a year later.

> Using the scripts? Both are in `config/prep.env`:
>
> ```sh
> # ===== EDIT IN: config/prep.env on the CONNECTED BASTION =====
> OCP_VERSION="4.21.28"        # was 4.21.26
> EXPORT_TAG="2026-12-01_z-stream-4.21.28"
> ```

Then regenerate with the same profiles as before:

```sh
# ===== RUN ON: CONNECTED BASTION =====
./scripts/12-compose-imageset.sh virtualization storage-lvms compliance-stig
```

To mirror an upgrade *path* rather than replace the pinned version, set a
range by hand in the generated config:

```yaml
    channels:
      - name: stable-4.21
        type: ocp
        minVersion: 4.21.26      # currently installed
        maxVersion: 4.21.28      # target
```

Keeping the installed version in range matters: it lets the cluster compute
an upgrade edge rather than discovering only an unreachable target.

For a **new operator**, add the profile (or edit the generated config) and
leave the version alone.

### 2. Check what will move

```sh
# ===== RUN ON: CONNECTED BASTION =====
./scripts/15-dry-run.sh
```

`working-dir/dry-run/missing.txt` lists what is not already cached — a good
proxy for the real download size.

### 3. Mirror

```sh
# ===== RUN ON: CONNECTED BASTION =====
./scripts/20-mirror-to-disk.sh
```

Same `MIRROR_OUT` as before. The script reports which mode it is in:

```
[INFO]  Incremental history found -- this run produces a DIFFERENTIAL archive.
```

If it says `FULL archive` and you expected a delta, stop. Either the
history is gone or `MIRROR_OUT` changed.

### 4. Package

```sh
# ===== RUN ON: CONNECTED BASTION =====
./scripts/30-package-transfer.sh
```

Delta transfers carry only the archives, config and checksums — the tooling
is already on the other side.

---

## Registry host

### 5. Verify and push

```sh
# ===== RUN ON: REGISTRY HOST =====
: "${OCP_AIRGAP_ROOT:?set it first -- see 01-prerequisites.md}"
cd ${OCP_AIRGAP_ROOT}/imports/2026-12-01_z-stream-4.21.28
sha256sum -c SHA256SUMS

cd ${OCP_AIRGAP_ROOT}
EXPORT_TAG=2026-12-01_z-stream-4.21.28 ./scripts/60-push-to-registry.sh
```

Note this is the **full `oc-mirror` command**, with `--v2`, `--config` and
`--from`. A delta push is not a different or shorter command — abbreviated
forms seen in some guides are missing required flags.

### 6. Re-verify

```sh
# ===== RUN ON: REGISTRY HOST =====
EXPORT_TAG=2026-12-01_z-stream-4.21.28 ./scripts/80-verify-mirror.sh
```

For an upgrade, extract the matching installer too — the binary is
version-specific:

```sh
# ===== RUN ON: REGISTRY HOST =====
EXPORT_TAG=2026-12-01_z-stream-4.21.28 ./scripts/70-extract-installer.sh
```

### 7. Hand off

```sh
# ===== RUN ON: REGISTRY HOST =====
EXPORT_TAG=2026-12-01_z-stream-4.21.28 ./scripts/90-handoff.sh
```

Each delta produces new `cluster-resources/`, and they must be applied —
new content frequently means new mirror entries.

---

## The whole cycle by hand

Without this repo, the delta cycle is six commands. The only thing that
makes it a *delta* is reusing the same `--cache-dir` and the same `file://`
destination.

Steps 3 and 5 are the long ones. Run each in a session that survives a
dropped connection, on whichever host you are on at the time:

```sh
# ===== RUN ON: BOTH HOSTS =====
systemd-run --scope --user tmux new -s day2
# detach with Ctrl-b d · reattach later with: tmux attach -t day2
```

**Connected bastion**

```sh
# ===== RUN ON: CONNECTED BASTION =====
cd ${OCP_AIRGAP_ROOT}
umask 0022                       # oc-mirror requires 0022; STIG sets 0077

# 1. edit config/imageset-config.yaml -- bump the version, or add packages

# 2. check what will move (minutes, no download)
oc-mirror --v2 \
  --config config/imageset-config.yaml \
  --cache-dir ./cache \
  --authfile binaries/pull-secret.json \
  --dry-run file://./mirror-out

# 3. mirror -- SAME destination as last time, or you get a full archive
oc-mirror --v2 \
  --config config/imageset-config.yaml \
  --cache-dir ./cache \
  --authfile binaries/pull-secret.json \
  file://./mirror-out

# 4. stage a dated copy for transport, then checksum it
TAG=2026-12-01_day2
mkdir -p exports/${TAG}
cp mirror-out/mirror_*.tar config/imageset-config.yaml exports/${TAG}/
cd exports/${TAG} && \
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
```

A delta transfer needs only the archives, the config and the checksums —
the tooling is already on the far side.

**Registry host**

```sh
# ===== RUN ON: REGISTRY HOST =====
cd ${OCP_AIRGAP_ROOT}
umask 0022
TAG=2026-12-01_day2

# 5. verify the transfer, then push
cd imports/${TAG} && sha256sum -c SHA256SUMS && cd ${OCP_AIRGAP_ROOT}

oc-mirror --v2 \
  --config imports/${TAG}/imageset-config.yaml \
  --from file://${OCP_AIRGAP_ROOT}/imports/${TAG} \
  --cache-dir /data/cache \
  --authfile binaries/mirror-pull-secret.json \
  docker://registry.example.com:8443

# 6. the regenerated manifests -- apply these to the cluster
ls imports/${TAG}/working-dir/cluster-resources/
```

`--from` must be an **absolute** path. `--config` is required even here.

If the push reports failures, it is resumable — lower the concurrency and
run it again:

```sh
# ===== RUN ON: REGISTRY HOST =====
oc-mirror --v2 --config ... --from ... --cache-dir ... --authfile ... \
  --parallel-images 2 --parallel-layers 2 \
  docker://registry.example.com:8443
```

Transient `405 METHOD NOT ALLOWED` errors on the registry's token endpoint
are common when pushing many images at once to a small registry host, and
this is the remedy. See [troubleshooting.md](troubleshooting.md).

### Confirming the new content actually landed

Mirrored operator images are referenced **by digest, not by tag**, so
checking `repo:latest` against the mirror fails even when the content is
present. Take a digest from the push output and resolve it against the
mirror:

```sh
# ===== RUN ON: REGISTRY HOST =====
oc image info --registry-config binaries/mirror-pull-secret.json \
  --filter-by-os linux/amd64 \
  registry.example.com:8443/<repo>@sha256:<digest>
```

---

## Cluster side (not this repo)

Steps 1–7 above are online: mirroring, transfer and push all run beside a
live cluster, which keeps serving from the registry throughout and sees
nothing new until the manifests below are applied. The reboots are the only
part that disrupts anything.

For completeness, what the install side does with a delta:

```sh
# ===== RUN ON: THE CLUSTER (install side) =====
oc apply -f cluster-resources/

# for an upgrade
oc adm upgrade --to=4.21.28
```

Each delta refreshes the graph-data image, so OSUS learns about the new
release once `cluster-resources/` is applied. Give it a minute, then
`oc adm upgrade` should list 4.21.28 as available before you ask for it.

> **Mirrored with `graph: false`?** Then there is no OSUS and no
> recommended updates, so `--to` has nothing to select from. Name the
> payload by digest instead:
>
> ```sh
> DIGEST=$(oc adm release info -o 'jsonpath={.digest}{"\n"}' \
>   registry.airgap.local:8443/openshift/release-images:4.21.28-x86_64)
>
> oc adm upgrade --allow-explicit-upgrade \
>   --to-image registry.airgap.local:8443/openshift/release-images@${DIGEST}
> ```
>
> [Updating a cluster in a disconnected environment](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/disconnected_environments/updating-a-cluster-in-a-disconnected-environment)

Applying IDMS/ITMS reboots nodes. On a single-node cluster, so does the
upgrade. Both are outages; schedule accordingly.

---

## Keeping deltas working

Protect these on the connected bastion. Losing either converts the next
"small update" into a full re-mirror.

| Path | Loss means |
|---|---|
| `mirror-out/working-dir/.history/` | every future archive is full |
| `cache/` | re-download from upstream |

If the connected bastion is rebuilt, restore both before the next run.

**Recovering from a lost archive** — if an archive is destroyed in transit
and you need a full one regenerated, delete the history deliberately:

```sh
# ===== RUN ON: CONNECTED BASTION =====
rm -rf ${OCP_AIRGAP_ROOT}/mirror-out/working-dir/.history
./scripts/20-mirror-to-disk.sh          # full archive again
```

**Recovering a cache from archives** — if the cache is lost but you still
hold the tars:

```sh
# ===== RUN ON: CONNECTED BASTION =====
for a in ${OCP_AIRGAP_ROOT}/exports/*/mirror_*.tar; do
  tar xf "$a" -C ${OCP_AIRGAP_ROOT}/cache/.oc-mirror/.cache docker/
done
```

---

## Cadence

Plan one prep cycle per cluster upgrade, and treat "we need operator X" as
the same cost. In environments where transfers are scheduled rather than
on-demand, batch them: it is cheaper to mirror three operators you might
need than to arrange three transfer windows.

This is the argument for over-mirroring at
[chapter 2](02-plan-your-content.md) time.

Every retained version also costs disk, permanently — roughly 19 GiB in the
registry and again in each cache. Once you are running this loop regularly,
read [10-capacity-planning.md](10-capacity-planning.md) and decide a
retention policy before the registry decides one for you.
