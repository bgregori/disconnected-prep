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

## Connected bastion

### 1. Update the configuration

For a z-stream upgrade, edit `config/prep.env`:

```sh
OCP_VERSION="4.21.28"        # was 4.21.26
EXPORT_TAG="2026-12-01_z-stream-4.21.28"
```

Then regenerate with the same profiles as before:

```sh
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
./scripts/15-dry-run.sh
```

`working-dir/dry-run/missing.txt` lists what is not already cached — a good
proxy for the real download size.

### 3. Mirror

```sh
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
./scripts/30-package-transfer.sh
```

Delta transfers carry only the archives, config and checksums — the tooling
is already on the other side.

---

## Disconnected bastion

### 5. Verify and push

```sh
cd ~/ocp-airgap/imports/2026-12-01_z-stream-4.21.28
sha256sum -c SHA256SUMS

cd ~/ocp-airgap
EXPORT_TAG=2026-12-01_z-stream-4.21.28 ./scripts/60-push-to-registry.sh
```

Note this is the **full `oc-mirror` command**, with `--v2`, `--config` and
`--from`. A delta push is not a different or shorter command — abbreviated
forms seen in some guides are missing required flags.

### 6. Re-verify

```sh
EXPORT_TAG=2026-12-01_z-stream-4.21.28 ./scripts/80-verify-mirror.sh
```

For an upgrade, extract the matching installer too — the binary is
version-specific:

```sh
EXPORT_TAG=2026-12-01_z-stream-4.21.28 ./scripts/70-extract-installer.sh
```

### 7. Hand off

```sh
EXPORT_TAG=2026-12-01_z-stream-4.21.28 ./scripts/90-handoff.sh
```

Each delta produces new `cluster-resources/`, and they must be applied —
new content frequently means new mirror entries.

---

## Cluster side (not this repo)

For completeness, what the install side does with a delta:

```sh
oc apply -f cluster-resources/

# for an upgrade
oc adm upgrade --to=4.21.28
```

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
rm -rf ~/ocp-airgap/mirror-out/working-dir/.history
./scripts/20-mirror-to-disk.sh          # full archive again
```

**Recovering a cache from archives** — if the cache is lost but you still
hold the tars:

```sh
for a in ~/ocp-airgap/exports/*/mirror_*.tar; do
  tar xf "$a" -C ~/ocp-airgap/cache/.oc-mirror/.cache docker/
done
```

---

## Cadence

Plan one prep cycle per cluster upgrade, and treat "we need operator X" as
the same cost. In environments where transfers are scheduled rather than
on-demand, batch them: it is cheaper to mirror three operators you might
need than to arrange three transfer windows.

This is the argument for over-mirroring at
[chapter 3](03-plan-your-content.md) time.

Every retained version also costs disk, permanently — roughly 19 GiB in the
registry and again in each cache. Once you are running this loop regularly,
read [11-capacity-planning.md](11-capacity-planning.md) and decide a
retention policy before the registry decides one for you.
