# Push to the registry

On the **registry host**. Unpacks the transferred archives into Quay
and generates the cluster manifests.

```sh
# ===== RUN ON: REGISTRY HOST =====
./scripts/60-push-to-registry.sh
```

---

## Verify the transfer first

```sh
# ===== RUN ON: REGISTRY HOST =====
: "${OCP_AIRGAP_ROOT:?set it first -- see 01-prerequisites.md}"
cd ${OCP_AIRGAP_ROOT}/imports/2026-10-02_initial
sha256sum -c SHA256SUMS
```

Do not skip this. The failure mode for a truncated archive is an error deep
in the push, hours later, that points at the registry rather than the media.

---

## Tooling

Already installed — [05-registry.md](05-registry.md#stage-the-transferred-tooling)
stages the transferred binaries and allowlists them on this host. Confirm
before starting a run that takes hours:

```sh
# ===== RUN ON: REGISTRY HOST =====
oc version --client
( umask 0022; oc-mirror version --v2 >/dev/null && echo "oc-mirror OK" )
```

---

## Push

This runs for hours, and a dropped SSH session kills it. Start a session
that survives one, then run the push inside it:

```sh
# ===== RUN ON: REGISTRY HOST =====
systemd-run --scope --user tmux new -s push
# detach with Ctrl-b d · reattach later with: tmux attach -t push
```

A bare `tmux new` is not enough — without the `systemd-run --scope`
wrapper the session belongs to your login scope and dies with it.
Lingering is already enabled from the Quay install, which is the other
half of surviving a logout.

Then, inside that session:

```sh
# ===== RUN ON: REGISTRY HOST =====
cd ${OCP_AIRGAP_ROOT}

export TMPDIR=/data/tmp
umask 0022 && oc-mirror --v2 \
  --config imports/2026-10-02_initial/imageset-config.yaml \
  --from file://${OCP_AIRGAP_ROOT}/imports/2026-10-02_initial \
  --cache-dir ./cache \
  --authfile binaries/mirror-pull-secret.json \
  docker://registry.airgap.local:8443
```

This is **disk-to-mirror (d2m)**. Points to note:

- **`--from` takes an absolute path.** A relative path is a common and
  confusingly-reported failure.
- **`--config` is still required.** It selects which subset of the archive
  to publish — the same archive can serve several enclaves with different
  configurations.
- **`--cache-dir` needs real space here too**, separate from `QUAY_ROOT`.
- **`umask 0022`** so the generated manifests are readable by whoever
  applies them later.
- **`TMPDIR`** because the push is where this bites hardest: unset, blobs
  stage in `/var/tmp`, a separate 5 GB filesystem under STIG. Set it
  durably rather than per-shell —
  [01-prerequisites.md](01-prerequisites.md#where-the-prep-tree-lives) has the
  drop-in, and
  [the appendix](appendix-fips-stig.md#tmpdir-defaults-to-a-stig-partition)
  has the why.

Expect hours: 27 minutes for 202 images on the validated 2 vCPU host, and
it scales with the content set.

---

## Read the error file, not the results table

The summary oc-mirror prints at the end counts what it *completed*, not
what failed. A single worker error aborts its batch, and everything the
batch had not reached is reported as unmirrored:

```
 ✗  1 / 192 release images mirrored: Some release images failed to be mirrored
 ✗  0 / 8 operator images mirrored
 ✗  0 / 3 additional images mirrored
```

That looks like 202 failures. The authoritative count is the file it names
on the last line:

```sh
# ===== RUN ON: REGISTRY HOST =====
sed 's/sha256:[0-9a-f]*/sha256:…/g' \
  ${OCP_AIRGAP_ROOT}/imports/${TAG}/working-dir/logs/mirroring_errors_*.txt \
  | sort | uniq -c | sort -rn
```

One line there means one failure, and everything else was collateral.

**The `405` namespace race, specifically.** The first push of a
multi-architecture image into a namespace that does not exist yet fails
with

```
trying to reuse blob ... at destination: Requesting bearer token:
received unexpected HTTP status: 405 METHOD NOT ALLOWED
```

A manifest list fans out into one copy per architecture; those run in
parallel and race to create the namespace, and Quay answers one of the
concurrent token requests `405`. This reproduces — it was seen on three
separate clean builds, always on the first push, always confined to the
namespaces being created for the first time, four failures out of 1,644
token requests.

It is also self-correcting. **Run the same command again**: the namespaces
now exist and the images go through. `60-push-to-registry.sh` detects that
every failure was a 405 and retries once by itself.

**Retrying is cheap in effort, not in time.** The push resumes and
already-pushed images are skipped, but oc-mirror re-extracts the whole
archive first — minutes before it reaches the part that can skip anything.

If the *same* image fails twice, it is not the race. For errors against
your own registry under load, reduce concurrency:

```sh
--parallel-images 2 --parallel-layers 2
```

A 2 vCPU Quay serving a token request per image is the usual reason a
self-hosted registry gets flaky partway through a large push.

---

## What this generates

Beyond pushing images, d2m writes the manifests that connect a cluster to
this registry. They land at the **`--from` path**:

```
imports/2026-10-02_initial/working-dir/cluster-resources/
├── idms-oc-mirror.yaml        ImageDigestMirrorSet
├── itms-oc-mirror.yaml        ImageTagMirrorSet
├── cs-redhat-operator-index-v4-21.yaml    CatalogSource (OLM v0)
├── cc-redhat-operator-index-v4-21.yaml    ClusterCatalog (OLM v1)
├── signature-configmap.yaml   release signature ConfigMap
├── signature-configmap.json   the same, as JSON
└── updateService.yaml         OSUS instance (only with `graph: true`)
```

> These files are the main artifact prep produces. Everything else is
> content; this is the configuration that makes the content reachable.

📌 **Handoff** The IDMS serves two distinct purposes, and both are required:

1. **Before install** — its contents must be transcribed into
   `install-config.yaml` as `imageDigestSources`. Without this the agent ISO
   tries to reach `quay.io` during bootstrap and the install hangs with no
   useful error. `90-handoff.sh` generates this fragment.
2. **After install** — applied to the running cluster as IDMS objects, so
   subsequent pulls are redirected.

Missing step 1 is the single most common disconnected-install failure.

---

## Confirm it landed

```sh
# ===== RUN ON: REGISTRY HOST =====
TAG=2026-10-02_initial
VER=$(awk '/minVersion:/{print $2; exit}' \
  ${OCP_AIRGAP_ROOT}/imports/${TAG}/imageset-config.yaml)

oc adm release info \
  --registry-config ${OCP_AIRGAP_ROOT}/binaries/mirror-pull-secret.json \
  registry.airgap.local:8443/openshift/release-images:${VER}-x86_64
```

The version comes out of the ImageSetConfiguration you mirrored rather
than being retyped. A literal that disagrees with the archive fails as
`manifest unknown: manifest unknown`, which reads like a broken push and
is really a wrong tag.

That is the check that matters: it pulls the release manifest back out of
your registry with the same credentials the push used.

> **`--registry-config`, not `--authfile`.** The two tools spell it
> differently — `oc-mirror` takes `--authfile`, every `oc` subcommand takes
> `-a` / `--registry-config` — and this chapter runs them back to back
> against the same file. `--authfile` on an `oc` command fails with
> `error: unknown flag: --authfile`.

To see every repository that landed, the registry catalog needs a **bearer
token** — Quay's `/v2/` endpoints do not accept Basic credentials. Fetch
one, then use it:

```sh
# ===== RUN ON: REGISTRY HOST =====
REG=registry.airgap.local:8443
TOKEN=$(curl -s -u init \
  "https://${REG}/v2/auth?service=${REG}&scope=registry:catalog:*" | jq -r .token)

curl -s -H "Authorization: Bearer ${TOKEN}" "https://${REG}/v2/_catalog" | jq .
```

`curl -u init` with no colon prompts for the password, keeping it out of
your shell history and out of `/proc/<pid>/cmdline`. Passing credentials
straight to `/v2/_catalog` instead returns

```json
{"error": "Invalid bearer token format"}
```

which reads like a malformed credential and is really just the wrong
authentication scheme — the registry API speaks bearer tokens, and
`/v2/auth` is where you get one.

`oc-mirror` v2 publishes the release payload at
`<registry>/openshift/release-images`, preserving upstream repository
structure for everything else.

A full verification pass is the next chapter — these two commands are just a
quick sanity check before moving on.

---

## If the push fails partway

It is resumable. Re-run the same command; already-pushed images are skipped.

Re-running is not free, though: oc-mirror re-verifies the checksum (minutes
for a large archive) and re-extracts the whole archive before it resumes.
If the first attempt already verified the same files, skip the re-hash:

```sh
# ===== RUN ON: REGISTRY HOST =====
SKIP_CHECKSUM=true ./scripts/60-push-to-registry.sh
```

The script also records `.checksum-verified` in the import directory after
a successful check and skips automatically on later runs; delete that file
to force re-verification. Running oc-mirror by hand skips the check anyway,
since it is this repo's addition rather than an oc-mirror feature.

Common causes:

| Error | Cause |
|---|---|
| `x509: certificate signed by unknown authority` | CA not in the host trust store — see [06](05-registry.md) |
| `unauthorized` | auth file key does not match the `docker://` target exactly, port included |
| `no space left on device` | `QUAY_ROOT` or `--cache-dir` full |
| `either --from or --workspace need to be provided` | missing `--from` with a `docker://` destination |
| `use the mandatory --config flag` | `--config` omitted; required even for d2m |

More in [troubleshooting.md](troubleshooting.md).

---

Next: [07-verify.md](07-verify.md)
