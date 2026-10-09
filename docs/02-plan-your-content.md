# Plan your content

The most consequential step in prep, and the one most often rushed.

Everything you mirror is decided here. Anything you leave out is not
installable in the disconnected environment, and adding it later means
another full trip across the airgap — on a classified network, that can be
days of scheduling for a five-minute mistake.

So the question to answer precisely, before running anything:

> **What will anyone need to install on this cluster, ever?**

> **Needs the tooling.** Sections 2 and 4 run `oc` and `oc-mirror` against
> `${OCP_AIRGAP_ROOT}/binaries/pull-secret.json`. Install them first —
> [01-prerequisites.md](01-prerequisites.md#install-the-tooling). Section 1
> is pure planning and needs nothing.

---

## 1. Inventory what you need

Work through these. "Probably not" is a yes — the marginal cost of an extra
operator is gigabytes; the cost of omitting one is a week.

**Platform**

- [ ] Exact OpenShift version (pinned z-stream, e.g. `4.21.34`)
- [ ] Architecture(s)
- [ ] Running **without** the OpenShift Update Service? → `graph: false`
      → *the default is `graph: true`, which mirrors the update graph so
      OSUS can run in-cluster and the cluster offers recommended updates.
      Turning it off means upgrading by digest with
      `--to-image --allow-explicit-upgrade` — supported, but the cluster
      will list no available updates. Reversing the choice later costs
      another mirror run and another trip across the airgap.*

**Workload platform**

- [ ] Virtualization (CNV)? → which guest OSes? Windows?
- [ ] Service Mesh, Serverless, Pipelines, GitOps?

**Storage** — exactly one is usually right

- [ ] LVM Storage (local disk, single-node/edge)
- [ ] OpenShift Data Foundation (multi-node, replicated)
- [ ] A CSI driver for existing storage

**Security and compliance**

- [ ] Compliance Operator (STIG/CIS scanning)
- [ ] File Integrity Operator (AIDE)
- [ ] Advanced Cluster Security

**Operations**

- [ ] Backup (OADP) — and is there an S3-compatible target?
- [ ] Logging, monitoring beyond the built-in stack

**Day-2 realism**

- [ ] Will you upgrade this cluster? Plan a prep cycle per upgrade.
- [ ] Will anyone need to debug it? Mirror `support-tools` and
      `must-gather` now. They are in `base-platform.yaml` for this reason —
      when you need them, you cannot download them.

---

## 2. Discover what is actually available

Do not guess package names or channels. A typo here surfaces hours into a
mirror run, or worse, silently mirrors nothing for that entry.

With this repo:

```sh
# ===== RUN ON: CONNECTED BASTION =====
./scripts/13-catalog.sh --list              # every package in the catalog
./scripts/13-catalog.sh --list oadp         # ...filtered
./scripts/13-catalog.sh lvms-operator       # channels and versions
./scripts/13-catalog.sh --check             # validate your config
```

### By hand

The script is a convenience wrapper; these are the commands it runs. Pull
the catalog's file-based catalog down once, then query it locally.

```sh
# ===== RUN ON: CONNECTED BASTION =====
: "${OCP_AIRGAP_ROOT:?set it first -- see 01-prerequisites.md}"
CATALOG=registry.redhat.io/redhat/redhat-operator-index:v4.21
PULL_SECRET=${OCP_AIRGAP_ROOT}/binaries/pull-secret.json

mkdir -p ~/catalog
oc image extract "${CATALOG}" \
  --registry-config "${PULL_SECRET}" \
  --filter-by-os linux/amd64 \
  --path "/configs/:${HOME}/catalog" --confirm
```

> The **trailing slash** on `/configs/` is required. Without it the command
> exits 0 and extracts nothing, which looks like an empty catalog.

That gives one directory per package:

```sh
# ===== RUN ON: CONNECTED BASTION =====
ls ~/catalog | wc -l                        # ~150 packages
ls ~/catalog | grep -i oadp                 # find a package
```

Each `catalog.json` is a stream of JSON objects, which `jq` reads directly:

```sh
# ===== RUN ON: CONNECTED BASTION =====
PKG=lvms-operator

# the default channel
jq -r 'select(.schema=="olm.package") | .defaultChannel' ~/catalog/${PKG}/catalog.json

# every channel
jq -r 'select(.schema=="olm.channel") | .name' ~/catalog/${PKG}/catalog.json | sort -u

# bundle versions within one channel
jq -r 'select(.schema=="olm.channel" and .name=="stable-4.21") | .entries[].name' \
   ~/catalog/${PKG}/catalog.json
```

Use the **channel** name in your ImageSetConfiguration, not the bundle
version.

> **Why not `oc-mirror list operators`?** It is widely documented, and it
> does not work here. `list`, `describe` and `init` exist only in
> oc-mirror v1, so they need an explicit `--v1`; the v1 path then extracts
> an embedded binary into a temp directory and executes it, which fapolicyd
> refuses on a STIG-hardened host:
>
> ```
> fork/exec /tmp/oc-mirror-*/oc-mirror: operation not permitted
> ```
>
> Making it work means trusting an executable in a user-writable directory
> — exactly what the hardening prevents. `13-catalog.sh` uses only the
> already-trusted `oc` binary. (Newer oc-mirror releases are reported to
> implement `list` under `--v2`; if yours does, either works.)

Package names and channels are inconsistent, and guessing them is a
frequent source of silent mistakes. Verified against the v4.21 catalog:

| Operator | Package name | Channel |
|---|---|---|
| Virtualization | `kubevirt-hyperconverged` | `stable` |
| NMState | `kubernetes-nmstate-operator` | `stable` |
| LVM Storage | `lvms-operator` | `stable-4.21` (tracks OCP version) |
| Compliance | `compliance-operator` | `stable` |
| File Integrity | `file-integrity-operator` | `stable` |
| **OADP / backup** | **`redhat-oadp-operator`** | `stable` |
| **Update Service (OSUS)** | **`update-service-operator`** | `v1` |
| GitOps | `openshift-gitops-operator` | `latest` |
| ACS | `rhacs-operator` | `stable` |

OADP is the cautionary one: the package is `redhat-oadp-operator`, but its
bundles are named `oadp-operator.vX.Y.Z`, so `oadp-operator` looks right
and appears in plenty of guides — including the one this repo came from.

OSUS is the same shape of trap: `cincinnati-operator` is the upstream
project and the name of the bundle image in the Red Hat catalog, but the
OLM package is `update-service-operator`. It is in `base-platform.yaml`
already, because `graph: true` mirrors the graph data this operator exists
to serve — mirroring one without the other leaves the cluster still
reporting no available updates.

Run `./scripts/13-catalog.sh --check` rather than trusting any table,
including this one. A wrong name is reported by oc-mirror only as
`collection error: no related images found`, with no indication of which
package is at fault — so with several operators configured you are left
bisecting.

---

## 3. Compose the configuration

> Working without this repo? Skip to
> [writing it by hand](#writing-it-by-hand) — the composer only
> concatenates fragments, and the finished file is short.

Profiles live in `imageset-configs/`, **in your clone of this repository**
— not in `${OCP_AIRGAP_ROOT}/`, which holds only the artifacts of a run.
`base-platform.yaml` is always included; each profile adds operators and
images for one capability.

```sh
# ===== RUN ON: CONNECTED BASTION =====
./scripts/12-compose-imageset.sh                 # list available profiles
./scripts/12-compose-imageset.sh virtualization storage-lvms compliance-stig
```

This writes `${IMAGESET_CONFIG}`, merging operators that share a catalog
into one entry and substituting your version variables.

**Read the profile files, not just their names.** Several document
obligations that land on the install side and are not discoverable later —
most importantly `virtualization.yaml`, below.

The generated file is yours. Hand-edit it freely; just remember re-running
the composer overwrites it, so put changes you want to keep into
`imageset-configs/`.

### Writing it by hand

You do not need the composer — it only concatenates fragments. A complete,
working configuration is short. This is the one actually used for the
validated run in [VALIDATION.md](../VALIDATION.md), with the operator list
to edit.

Write it to `${OCP_AIRGAP_ROOT}/config/imageset-config.yaml` — the `config/`
directory created with the rest of the prep tree in
[01-prerequisites.md](01-prerequisites.md#install-the-tooling). Every later
chapter refers to this file as `${IMAGESET_CONFIG}`.

```sh
# ===== RUN ON: CONNECTED BASTION =====
${EDITOR} ${OCP_AIRGAP_ROOT}/config/imageset-config.yaml
```

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1

# Split archives to fit your transport medium, in GB. Remove for the
# 500 GB default.
archiveSize: 100

mirror:
  platform:
    architectures:
      - "amd64"
    channels:
      # minVersion == maxVersion pins to a single z-stream. A range mirrors
      # every release between the two.
      - name: stable-4.21
        type: ocp
        minVersion: 4.21.34
        maxVersion: 4.21.34
    # Mirrors the update graph so the OpenShift Update Service can run
    # in-cluster. false means upgrading by digest instead -- see the
    # planning checklist above before changing it.
    graph: true

  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.21
      packages:
        # Pairs with `graph: true` above: the graph data is what this
        # operator serves, and without it the cluster still reports no
        # available updates. Drop both together, not one.
        # NOT `cincinnati-operator` -- that is the upstream image name.
        - name: update-service-operator
          channels:
            - name: v1
        - name: compliance-operator
          channels:
            - name: stable
        - name: file-integrity-operator
          channels:
            - name: stable

  additionalImages:
    # Diagnostics. Mirror them now; you cannot fetch them later, which is
    # exactly when you will want them.
    - name: registry.redhat.io/rhel9/support-tools:latest
    - name: registry.redhat.io/openshift4/ose-must-gather:latest
    - name: registry.redhat.io/ubi9/ubi:latest
```

Notes for hand-editing:

- **One `- catalog:` entry per catalog**, with all packages beneath it.
  Repeating the same catalog key creates redundant mirrors.
- The catalog tag tracks the OpenShift **minor** version (`v4.21`), while
  `minVersion`/`maxVersion` are full z-stream versions.
- Channel names are inconsistent between operators — check each one
  against the catalog, as above.
- Omitting `channels:` for a package mirrors its default channel.

Verified package names and channels for the profiles this repo ships are
in the table above.

### Sizing the archive to your transport

```yaml
archiveSize: 100     # GB per archive segment
```

Set this to fit your transport medium. With `--strict-archive`, a single
file larger than the limit is an error rather than an oversized segment —
use it when the medium has a hard cap.

---

## 4. Validate before you download

Two cheap checks before committing to a multi-hour run.

```sh
# ===== RUN ON: CONNECTED BASTION =====
./scripts/13-catalog.sh --check   # names and channels resolve? (seconds)
./scripts/15-dry-run.sh           # full resolution against the catalog
```

By hand, the dry run is the same mirror command with `--dry-run`:

```sh
# ===== RUN ON: CONNECTED BASTION =====
cd ${OCP_AIRGAP_ROOT}
umask 0022
oc-mirror --v2 \
  --config config/imageset-config.yaml \
  --cache-dir ./cache \
  --authfile binaries/pull-secret.json \
  --dry-run file://./mirror-out
```

Resolves the whole configuration without transferring images, and writes:

- `working-dir/dry-run/mapping.txt` — every source→destination mapping
- `working-dir/dry-run/missing.txt` — what is not already cached

> **A passing dry run looks like a warning.** On a first run the cache is
> empty, so oc-mirror reports nearly every image as missing and tells you
> to re-run:
>
> ```
> ⚠️  202/203 images necessary for mirroring are not available in the cache.
> List of missing images in : mirror-out/working-dir/dry-run/missing.txt.
> please re-run the mirror to disk process
> ```
>
> That is the expected result, not a failure — `--dry-run` resolves
> images, it never downloads them, so there is nothing for it to have
> cached. What matters is that it reached `collecting additional images`
> and wrote `mapping.txt`. A real failure stops earlier, at
> `collection error: no related images found` (a wrong package name) or
> at the release or catalog collection step.
>
> The count is the useful number: it tells you how many images the mirror
> will actually move.

Read `mapping.txt`. Check that every operator you expect is present, that no
unexpected architectures crept in, and that the release image count looks
like one version rather than a range.

### Will it fit?

**Provision 500 GB on the registry host.** That covers the registry, the
oc-mirror cache and an import archive for any realistic content set, with
headroom for other use of the box. The connected bastion wants a similar
allowance for its own cache and archive staging.

There is no need to compute this per-configuration. For the reasoning, the
measured numbers behind it, and the cases where 500 GB is *not* enough —
chiefly retaining many OpenShift versions — see
[10-capacity-planning.md](10-capacity-planning.md).

Watch actual consumption as the mirror runs:

```sh
# ===== RUN ON: CONNECTED BASTION =====
du -sh ${OCP_AIRGAP_ROOT}/cache ${OCP_AIRGAP_ROOT}/mirror-out
df -h ${OCP_AIRGAP_ROOT}
```

---

## Obligations this creates for the install side

Some mirroring choices impose work on whoever installs the cluster.
Record these in the handoff.

### Virtualization: CDI ignores IDMS/ITMS

The most important one, and the least obvious.

IDMS and ITMS rewrite image references for **CRI-O**, which covers pods.
The Containerized Data Importer resolves the literal URL string in a
`DataVolume` or `DataImportCron` spec and never consults those rules.

So mirroring guest images is necessary but not sufficient. Default boot
sources will keep trying to reach `registry.redhat.io`, failing, and
retrying forever. The install side must:

1. Disable operator-managed boot source imports:
   ```sh
   oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv \
     --type merge \
     -p '{"spec":{"featureGates":{"enableCommonBootImageImport":false}}}'
   ```
2. Create static `DataVolume`s whose URLs point at the mirror registry
   explicitly, with names matching the PVC names the `DataSource`s expect.
3. Give CDI the registry CA via `spec.source.registry.certConfigMap` — the
   cluster-wide `additionalTrustBundle` does not automatically cover CDI
   imports.

### Windows guests need `virtio-win`

Not included unless you mirror it. It is in the `virtualization` profile.
Omit it and Windows VMs install without storage or network drivers.

### ACS needs offline vulnerability definitions

The scanner's CVE feed is a separate, recurring download. Mirroring the
operator does not provide it; without it the scanner silently reports
against stale data.

### Compliance auto-remediation reboots nodes

`default-auto-apply` applies STIG remediations as MachineConfigs, each
triggering a reboot. On a single-node cluster that is a full API outage,
repeated. Recommend binding to `default` (scan only) first.

---

## 5. Record the decision

Commit the generated `imageset-config.yaml` somewhere durable. You need it
for every Day-2 update, and it is the only record of what the environment
can install. `90-handoff.sh` copies it into the handoff bundle.

---

Next: [03-connected-mirror.md](03-connected-mirror.md)
