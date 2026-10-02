# Push to the registry

On the **disconnected** bastion. Unpacks the transferred archives into Quay
and generates the cluster manifests.

```sh
./scripts/60-push-to-registry.sh
```

---

## Verify the transfer first

```sh
cd ~/ocp-airgap/imports/2026-10-02_initial
sha256sum -c SHA256SUMS
```

Do not skip this. The failure mode for a truncated archive is an error deep
in the push, hours later, that points at the registry rather than the media.

---

## Install the tooling here too

If this is the first transfer:

```sh
cd ~/ocp-airgap/imports/2026-10-02_initial/binaries
sudo tar -xzf openshift-client-linux.tar.gz -C /usr/local/bin oc
sudo tar -xzf oc-mirror.rhel9.tar.gz -C /usr/local/bin oc-mirror
sudo chown root:root /usr/local/bin/oc /usr/local/bin/oc-mirror
sudo chmod 0755 /usr/local/bin/oc /usr/local/bin/oc-mirror

sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror
sudo fapolicyd-cli --file add /usr/local/bin/oc
sudo fapolicyd-cli --file add /usr/local/bin/oc-mirror
sudo fapolicyd-cli --update
```

> ⚠️ **STIG** The allowlist is per-host. Doing this on the connected
> bastion does nothing for this one.

---

## Push

```sh
cd ~/ocp-airgap

umask 0022 && oc-mirror --v2 \
  --config imports/2026-10-02_initial/imageset-config.yaml \
  --from file:///home/user/ocp-airgap/imports/2026-10-02_initial \
  --cache-dir ./cache \
  --authfile binaries/mirror-pull-secret.json \
  docker://bastion.airgap.local:8443
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

Expect hours. Use tmux.

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
└── signature-configmap.json   the same, as JSON
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
curl -s -u init:<password> \
  https://bastion.airgap.local:8443/v2/_catalog | python3 -m json.tool | head -40

oc adm release info \
  --authfile ~/ocp-airgap/binaries/mirror-pull-secret.json \
  bastion.airgap.local:8443/openshift/release-images:4.21.26-x86_64
```

`oc-mirror` v2 publishes the release payload at
`<registry>/openshift/release-images`, preserving upstream repository
structure for everything else.

A full verification pass is the next chapter — these two commands are just a
quick sanity check before moving on.

---

## If the push fails partway

It is resumable. Re-run the same command; already-pushed images are skipped.

Common causes:

| Error | Cause |
|---|---|
| `x509: certificate signed by unknown authority` | CA not in the host trust store — see [06](06-registry.md) |
| `unauthorized` | auth file key does not match the `docker://` target exactly, port included |
| `no space left on device` | `QUAY_ROOT` or `--cache-dir` full |
| `either --from or --workspace need to be provided` | missing `--from` with a `docker://` destination |
| `use the mandatory --config flag` | `--config` omitted; required even for d2m |

More in [troubleshooting.md](troubleshooting.md).

---

Next: [08-verify.md](08-verify.md)
