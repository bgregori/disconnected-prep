# Transfer

Moving the archive across the airgap. Short chapter, but the step with the
longest feedback loop when it goes wrong — a corrupted archive fails hours
into the registry push, often the next day.

```sh
./scripts/30-package-transfer.sh
```

### By hand

```sh
TAG=2026-10-02_initial
SRC=~/ocp-airgap/exports/${TAG}

# first transfer only: carry the tooling and these procedures too
mkdir -p "${SRC}/binaries"
cp ~/ocp-airgap/binaries/openshift-client-linux.tar.gz \
   ~/ocp-airgap/binaries/oc-mirror.rhel9.tar.gz \
   ~/ocp-airgap/binaries/mirror-registry.tar.gz "${SRC}/binaries/"

# checksum everything -- do this before the media leaves the host
cd "${SRC}"
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS

# copy to the medium (no -z: the content is already compressed)
cp -a "${SRC}" /path/to/removable/media/
```

On arrival:

```sh
cd ~/ocp-airgap/imports/${TAG} && sha256sum -c SHA256SUMS
```

---

## Do not re-compress

The archives are already compressed container layers. `tar -czf` over them
costs significant CPU time and typically saves under 2%.

Copy the directory as-is, or use an uncompressed `tar` if your transfer
process needs a single file.

---

## Check the destination has room first

Obvious, routinely skipped, and the failure happens at the end of a long
copy.

```sh
du -sh ~/ocp-airgap/exports/2026-10-02_initial
df -h /path/to/removable/media
df -h /path/to/disconnected/imports      # if you can see it
```

The disconnected bastion needs room for the imports **and** the registry
**and** the oc-mirror cache, simultaneously. See
[01-prerequisites.md](01-prerequisites.md#disk-concretely).

---

## What to carry

**First transfer** — archives, tooling, and these procedures:

```
exports/2026-10-02_initial/
├── mirror_000001.tar ...
├── imageset-config.yaml          required by the push step
├── binaries/
│   ├── openshift-client-linux.tar.gz
│   ├── oc-mirror.rhel9.tar.gz
│   └── mirror-registry.tar.gz
├── disconnected-prep-repo.tar    this repository
└── SHA256SUMS
```

**Later transfers** — archives, the config, and checksums. The tooling is
already there.

`scripts/30-package-transfer.sh` decides between the two by looking for
`${PREP_ROOT}/.binaries-transferred`, which it creates after the first
transfer. Delete that file to force the tooling to be included again — for
instance after upgrading `oc-mirror`, when the far side needs the matching
binary. Working by hand, just copy `binaries/` the first time and omit it
afterwards.

> The marker deliberately lives beside the prep tree rather than inside the
> export directory. A per-export marker is never present in a new dated
> export, so every delta would re-ship the tooling — about 840 MB.

> ⚠️ **STIG** Do not include the Red Hat pull secret. The disconnected side
> authenticates only to the local Quay, with credentials generated there.
> A production entitlement crossing into a classified enclave is a finding,
> and it is not needed.

---

## Checksum both ends

Non-negotiable at these sizes.

Before transfer:

```sh
cd ~/ocp-airgap/exports/2026-10-02_initial
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
```

After arrival:

```sh
cd ~/ocp-airgap/imports/2026-10-02_initial
sha256sum -c SHA256SUMS
```

`60-push-to-registry.sh` runs this automatically and refuses to proceed on a
mismatch. A silently truncated 400 GB archive otherwise fails deep inside
the push with an error that points at the registry rather than the media.

---

## Keep the export directory

Do not delete `exports/<tag>/` from the connected bastion once the transfer
succeeds. If the media is damaged or the push fails, having the archive
locally is the difference between recopying and re-mirroring.

Keep at least the most recent export until the cluster is installed and
verified.

---

## Media notes

- **Removable disk** — most common. Verify the filesystem supports your
  largest single file; FAT32 caps at 4 GB, which `archiveSize` must respect.
- **One-way data diode** — set `archiveSize` to the transfer unit the diode
  expects, and expect no acknowledgement; checksums are your only signal.
- **Physically relocating the drive** — note that a mirror-out directory
  relocated wholesale carries its `.history/`, which is useful if the
  connected bastion is rebuilt.

---

Next: [06-registry.md](06-registry.md)
