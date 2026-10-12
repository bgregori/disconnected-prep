# Transfer

Moving the archive across the airgap. Short chapter, but the step with the
longest feedback loop when it goes wrong — a corrupted archive fails hours
into the registry push, often the next day.

```sh
# ===== RUN ON: CONNECTED BASTION =====
./scripts/30-package-transfer.sh
```

### By hand

```sh
# ===== RUN ON: CONNECTED BASTION =====
: "${OCP_AIRGAP_ROOT:?set it first -- see 01-prerequisites.md}"
TAG=2026-10-02_initial
SRC=${OCP_AIRGAP_ROOT}/exports/${TAG}

# first transfer only: the tooling. Later deltas carry archives only.
mkdir -p "${SRC}/binaries"
cp ${OCP_AIRGAP_ROOT}/binaries/openshift-client-linux.tar.gz \
   ${OCP_AIRGAP_ROOT}/binaries/oc-mirror.rhel9.tar.gz \
   ${OCP_AIRGAP_ROOT}/binaries/mirror-registry.tar.gz "${SRC}/binaries/"
```

### Carry the procedures too, or not

The far side needs the three binaries above either way. Whether it also
gets *this repository* is a policy question, not a technical one, and both
answers are workable.

**If you can carry it** — add the repo to the bundle. The registry host
then has the chapters and the scripts locally, and
[05-registry.md](05-registry.md) can be followed from the host itself:

```sh
# ===== RUN ON: CONNECTED BASTION =====
REPO=~/disconnected-prep          # wherever this repository is checked out

tar -cf "${SRC}/disconnected-prep-repo.tar" \
    --exclude='.git' \
    --exclude='config/prep.env' \
    -C "$(dirname "${REPO}")" "$(basename "${REPO}")"
```

Two things about that command. `--exclude` must come **before** the path
arguments: GNU tar on RHEL 9 treats options after a non-option argument as
positional and fails with `--exclude has no effect`, exiting non-zero —
BSD tar is lenient, so this only breaks on the platform that matters.
And `config/prep.env` is excluded deliberately: it holds `QUAY_PASSWORD`,
and the registry host needs its own paths anyway. Write a fresh one there.

On arrival, unpack it before anything else:

```sh
# ===== RUN ON: REGISTRY HOST =====
tar -xf ${OCP_AIRGAP_ROOT}/imports/${TAG}/disconnected-prep-repo.tar -C ~
```

**If you cannot carry it** — many enclaves will not accept a tarball of
anything that is not reviewed content, and this repo is explicitly written
so you do not need it. Omit the step. The consequence is only that the
chapters live somewhere else: a printed copy, a PDF on an approved laptop,
or a controlled copy already inside the enclave. Every command in
[05-registry.md](05-registry.md) onward is written out in full for exactly
this case, and `config/prep.env` is typed rather than copied regardless.

What you lose without the repo is the `scripts/` convenience and nothing
else. The by-hand path is the whole procedure, not a summary of it.

### Finish the bundle

```sh
# ===== RUN ON: CONNECTED BASTION =====
# checksum everything -- do this before the media leaves the host
cd "${SRC}"
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS

# copy to the medium (no -z: the content is already compressed)
cp -a "${SRC}" /path/to/removable/media/
```

Checksum **after** deciding about the repo tarball, so the manifest covers
whatever is actually in the bundle.

On arrival:

```sh
# ===== RUN ON: REGISTRY HOST =====
cd ${OCP_AIRGAP_ROOT}/imports/${TAG} && sha256sum -c SHA256SUMS
```

Everything lands under `imports/${TAG}/`, including the tooling. Moving it
into the prep tree and installing it is the first section of
[05-registry.md](05-registry.md#stage-the-transferred-tooling) — nothing on
the registry host works until that is done.

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
# ===== RUN ON: CONNECTED BASTION =====
du -sh ${OCP_AIRGAP_ROOT}/exports/2026-10-02_initial
df -h /path/to/removable/media
df -h /path/to/disconnected/imports      # if you can see it
```

The registry host needs room for the imports **and** the registry
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
`${OCP_AIRGAP_ROOT}/.binaries-transferred`, which it creates after the first
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
# ===== RUN ON: CONNECTED BASTION =====
cd ${OCP_AIRGAP_ROOT}/exports/2026-10-02_initial
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
```

After arrival:

```sh
# ===== RUN ON: REGISTRY HOST =====
cd ${OCP_AIRGAP_ROOT}/imports/2026-10-02_initial
sha256sum -c SHA256SUMS
```

Both commands read every byte and hash it single-threaded, printing nothing
until they finish. Budget minutes, not seconds — 29 GB took several minutes
on a 2 vCPU host, and the cost is paid twice, once at each end. Hash on
local disk rather than on the removable medium, which is why the checksum
happens before the copy above. If it runs far longer than that, check you
are in the export directory: from `${OCP_AIRGAP_ROOT}`, `find .` also walks
`cache/` and its hundreds of thousands of small files.

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

Next: [05-registry.md](05-registry.md)
