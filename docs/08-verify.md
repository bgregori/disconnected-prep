# Verify

The gate. Nothing goes to the install team until this passes.

Every failure caught here costs minutes. The same failure caught after
someone has booted an ISO costs a day, and in a disconnected environment
possibly a scheduled transfer window.

```sh
./scripts/70-extract-installer.sh
./scripts/80-verify-mirror.sh
```

---

## Extract the FIPS installer

```sh
export REG=bastion.airgap.local:8443
export VER=4.21.26
export IDMS=~/ocp-airgap/imports/2026-10-02_initial/working-dir/cluster-resources/idms-oc-mirror.yaml

oc adm release extract \
  --registry-config ~/ocp-airgap/binaries/mirror-pull-secret.json \
  --command=openshift-install-fips \
  --from="${REG}/openshift/release-images:${VER}-x86_64" \
  --to=~/ocp-airgap/binaries \
  --idms-file="${IDMS}"

chmod +x ~/ocp-airgap/binaries/openshift-install-fips
~/ocp-airgap/binaries/openshift-install-fips version
```

Two things about this command.

**Use `--command=openshift-install-fips`, not `openshift-install`.** A
cluster with `fips: true` requires the FIPS-validated installer binary. The
generic installer from `mirror.openshift.com` will not do, and the mismatch
is not caught until late.

**`--idms-file` must be an absolute path.** `oc` resolves it relative to the
current directory. A relative path that happens to be wrong produces an
error about reaching the upstream registry, which sends you looking in
entirely the wrong place.

### Why this is the real verification

This single command exercises nearly everything prep is responsible for:

- registry reachability and TLS trust
- authentication
- IDMS resolution — can image references actually be rewritten
- release payload completeness — is every referenced layer present

If it succeeds and reports your expected version, the hard part is done.

---

## Run the checks

```sh
./scripts/80-verify-mirror.sh
```

| # | Check | Why |
|---|---|---|
| 1 | Registry API reachable over TLS | CA trust is correct, not bypassed |
| 2 | Release payload present and readable | the install has something to install |
| 3 | `openshift-install-fips` matches `OCP_VERSION` | right binary, right version |
| 4 | IDMS, CatalogSources, signatures generated | the cluster can be pointed at the mirror |
| 5 | Each catalog image is pullable | catalogs are servable, not merely pushed |
| 6 | Requested operators enumerated | a named list to confirm post-install |

The script exits non-zero on any failure.

---

## Checks worth doing by hand

### Resolve from the node network

The verification script runs on the registry host, where everything resolves. The
cluster does not live there.

```sh
# from a host on the node network
dig +short bastion.airgap.local
curl -I https://bastion.airgap.local:8443/v2/
```

This is the most common thing that passes on the registry host and fails for the
cluster.

### Spot-check an operator bundle

```sh
oc image info --registry-config ~/ocp-airgap/binaries/mirror-pull-secret.json \
  --filter-by-os linux/amd64 \
  bastion.airgap.local:8443/redhat/redhat-operator-index:v4.21
```

### Spot-check an additional image

Especially the easily-forgotten ones:

```sh
for img in \
  rhel9/support-tools:latest \
  openshift4/ose-must-gather:latest \
  container-native-virtualization/virtio-win:latest ; do
  echo -n "${img}: "
  oc image info --registry-config ~/ocp-airgap/binaries/mirror-pull-secret.json \
    --filter-by-os linux/amd64 "bastion.airgap.local:8443/${img}" >/dev/null 2>&1 \
    && echo OK || echo MISSING
done
```

### Confirm registry capacity for growth

```sh
du -sh /opt/quay
df -h /opt/quay
```

Day-2 updates add to this registry. If it is near full now, the first
upgrade fails.

---

## What this cannot verify

Be honest with the install team about the limits.

- **Per-image completeness of a push.** The gate checks the release
  payload, the catalog image and the generated manifests — it would not
  notice that one operator image failed to upload. That is enforced
  upstream instead: `60-push-to-registry.sh` exits non-zero and names the
  failures when oc-mirror reports a partial push. Do not treat a green gate
  as evidence that a failed push was harmless.
- **Operator installability.** That a catalog image is pullable does not
  prove every operator in it resolves its dependencies. Confirm with
  `oc get packagemanifests -n openshift-marketplace` once a cluster exists.
- **Guest boot sources.** Mirrored guest images are not proof that CDI can
  import them — CDI ignores IDMS and needs its own CA configuration. See
  [03-plan-your-content.md](03-plan-your-content.md#obligations-this-creates-for-the-install-side).
- **Cluster-side DNS, NTP, routing.** Outside prep's reach.
- **That you mirrored the right things.** Verification proves the mirror is
  internally consistent, not that it matches someone's intent. That was
  decided in chapter 3.

---

If everything passes, complete
[checklists/prep-acceptance.md](../checklists/prep-acceptance.md), then go
to [09-handoff.md](09-handoff.md).
