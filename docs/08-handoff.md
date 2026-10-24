---
title: "Handoff"
description: >-
  Producing the bundle the install side consumes: manifests, CA bundle, pull secret, and ready-to-paste install-config.yaml fragments.
---

# Handoff

The boundary. Prep produces a bundle; the install side consumes it.

```sh
# ===== RUN ON: REGISTRY HOST =====
./scripts/90-handoff.sh
```

Writes `${OCP_AIRGAP_ROOT}/handoff/<EXPORT_TAG>/`.

> Working without this repo? The script only collects files and reshapes
> the IDMS. See
> [building `imageDigestSources` by hand](#building-imagedigestsources-by-hand)
> below; the rest is `cp`.

---

## What prep owes the install side

Six artifacts and four facts. If any are missing, the install will fail in a
way that looks like an install problem but is not.

### Artifacts

| Artifact | Consumed as |
|---|---|
| `install-config-fragment.yaml` | `imageDigestSources` + `additionalTrustBundle` in `install-config.yaml` |
| `pull-secret.json` | the `pullSecret` value in `install-config.yaml` |
| `certs/rootCA.pem` | registry CA, also needed by anything else pulling from the mirror |
| `cluster-resources/` | applied **after** the install completes |
| `bin/openshift-install-fips` | ISO generation; required when `fips: true`, and must be **run on a host that is itself in FIPS mode** |
| `imageset-config.yaml` | the record of what exists; required for every Day-2 update |

### Facts

- **Registry endpoint** — `https://<host>:<port>`
- **Release payload reference** — `<registry>/openshift/release-images:<version>-<arch>`
- **What is installable** — the operator list, and by implication what is not
- **What is not mirrored** — architectures, versions, operators deliberately excluded

> ⚠️ **STIG** If the ISO-generating host runs fapolicyd, it needs the trust
> entry and the shared-library rule from
> [07-verify.md](07-verify.md#extract-the-fips-installer), written for the
> path the binary actually runs from there. The rule matches by path, so
> the one on the registry host does not cover the copy in `bin/`. The
> bundle's `README.md` includes the commands.

---

## The three install-config requirements

A disconnected install needs all three. Missing any one fails closed, and
the errors are not self-explanatory.

```yaml
fips: true
imageDigestSources: [...]        # see below
additionalTrustBundle: |         # see below
  -----BEGIN CERTIFICATE-----
  ...
additionalTrustBundlePolicy: Always
```

**`imageDigestSources` is the one that gets forgotten.** Without it the
agent ISO attempts to reach `quay.io` during bootstrap. On an airgapped
network that means the install hangs rather than failing cleanly, and the
bootstrap logs do not make the cause obvious.

---

## Disk encryption: the other decision made at install

`fips: true` is not the only hardening choice that cannot be revisited.
Boot-disk encryption on RHCOS is configured **at the manifest stage**, and
a cluster installed without it has to be reprovisioned to get it. For an
accredited build that usually means reinstalling after the finding, so it
belongs in this conversation rather than in a later one.

It is easy to miss precisely because it is *not* an `install-config.yaml`
field. It is a `MachineConfig` placed in `<install_dir>/openshift/` before
the ignition configs are generated — one for `master`, one for `worker` —
and RHCOS then encrypts the root filesystem with LUKS2, unlocked by
[Clevis](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/installing/installation-configuration)
in one of two modes:

| Mode | Unlocks when | Enclave precondition |
|---|---|---|
| **TPM v2** | the disk is still in its original machine | a TPM 2.0 device, enabled in firmware — and on virtual nodes, a vTPM attached to the guest |
| **Tang / NBDE** | the node can reach the Tang servers | one or more Tang servers reachable on the node network, and their thumbprints |

Both can be combined with a `threshold`, which is what you want if the
requirement is "decrypts only in this rack, on this network".

Two interactions worth stating to the install side:

- **FIPS changes the cipher.** With `fips: true` the LUKS2 volume uses
  `aes-cbc-essiv:sha256`. That is expected, not a misconfiguration.
- **Tang is infrastructure, not content.** Nothing here needs mirroring —
  no extra images, no change to the ImageSetConfiguration — but a Tang
  server that does not exist yet is a blocker discovered at install time,
  on the wrong side of the airgap.

Verify on a node afterwards, from a debug shell:

```sh
# ===== RUN ON: THE CLUSTER =====
lsblk --fs                    # root partition shows crypto_LUKS
cryptsetup status root        # type: LUKS2
```

📌 **Handoff** Record the decision either way. "Not encrypted, accepted by
the ISSO" is a valid answer; "nobody asked" is the one that costs a
rebuild.

### Building `imageDigestSources` by hand

`scripts/90-handoff.sh` generates this, but you do not need it. The entries
in the generated IDMS are **already the right shape** — `imageDigestSources`
takes a list of `{source, mirrors}` maps, and YAML maps are unordered, so
the `mirrors:`-before-`source:` ordering oc-mirror emits is fine as-is.

Open the generated IDMS:

```sh
# ===== RUN ON: REGISTRY HOST =====
cat <import-dir>/working-dir/cluster-resources/idms-oc-mirror.yaml
```

It looks like this:

```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-release-0
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:8443/openshift/release
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
  - mirrors:
    - registry.example.com:8443/openshift/release-images
    source: quay.io/openshift-release-dev/ocp-release
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-operator-0
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:8443/compliance
    source: registry.redhat.io/compliance
```

> ⚠️ **The file contains more than one YAML document.** oc-mirror writes a
> separate `ImageDigestMirrorSet` for the release images and for each
> operator source. Copying only the first one — the obvious mistake — gives
> you a cluster that can pull the platform but not the operators.

Take **every** list item under **every** `imageDigestMirrors:` block,
concatenate them into a single list, and put it under `imageDigestSources:`
in `install-config.yaml` at two-space indentation:

```yaml
imageDigestSources:
- mirrors:
  - registry.example.com:8443/openshift/release
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
- mirrors:
  - registry.example.com:8443/openshift/release-images
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - registry.example.com:8443/compliance
  source: registry.redhat.io/compliance
```

If you would rather not retype it, this prints the block ready to paste.
It uses only `awk` and `sed`, so there is no script file to create — which
matters on a host where fapolicyd blocks interpreters from opening
untrusted script files (see
[appendix-fips-stig.md](appendix-fips-stig.md)):

```sh
# ===== RUN ON: REGISTRY HOST =====
IDMS=<import-dir>/working-dir/cluster-resources/idms-oc-mirror.yaml

{ echo "imageDigestSources:"
  awk '/^  imageDigestMirrors:/ {f=1; next}
       /^[^ ]/                 {f=0}
       f' "${IDMS}" | sed 's/^  //'
}
```

Check the result: the number of `- mirrors:` lines in your
`install-config.yaml` must equal the number in the IDMS file.

```sh
# ===== RUN ON: REGISTRY HOST =====
grep -c '^\s*- mirrors:' <import-dir>/working-dir/cluster-resources/idms-oc-mirror.yaml
grep -c '^- mirrors:'     install-config.yaml
```

### `additionalTrustBundle` by hand

The registry CA, indented by two spaces under a literal block:

```sh
# ===== RUN ON: REGISTRY HOST =====
# prints the block ready to paste
{ echo "additionalTrustBundle: |"
  sed 's/^/  /' /path/to/rootCA.pem
  echo "additionalTrustBundlePolicy: Always"
}
```

`additionalTrustBundlePolicy: Always` matters for `platform: none` — without
it the bundle may only be applied to proxy connections rather than to
registry pulls.

### `pullSecret` by hand

The single-quoted contents of the mirror auth file, on one line:

```sh
# ===== RUN ON: REGISTRY HOST =====
echo "pullSecret: '$(cat /path/to/mirror-pull-secret.json)'"
```

---

## After the install completes

Apply the mirror configuration and turn off the internet catalogs:

```sh
# ===== RUN ON: THE CLUSTER (install side) =====
cd <bundle>/cluster-resources
oc apply -f idms-oc-mirror.yaml -f itms-oc-mirror.yaml \
  -f signature-configmap.yaml -f cs-*.yaml -f cc-*.yaml

oc patch operatorhub cluster --type merge \
  -p '{"spec":{"disableAllDefaultSources":true}}'
```

Turning off the default catalog sources matters because they point at
`registry.redhat.io`. In a disconnected environment they fail forever, which
shows up as `OperatorHubSourceError` and four marketplace pods stuck in
`ImagePullBackOff`.

Leave `updateService.yaml` out for now. `oc apply -f cluster-resources/`
fails on it with `no matches for kind "UpdateService"`, because the custom
resource definition comes from the OpenShift Update Service operator, and
that operator is not installed yet.

> **Applying IDMS/ITMS does not restart the node.** On 4.21 the machine
> config operator rewrites the CRI-O configuration, logs `Drain not required,
> skipping` and runs `systemctl reload crio`. It took 13 seconds on a
> single-node cluster, with no API outage.

### Run the OpenShift Update Service

These steps apply when the content was mirrored with `graph: true` (the
default) and includes `cincinnati-operator`. Without OSUS, the cluster shows
no available updates and you upgrade by digest. See
[09-day2-delta.md](09-day2-delta.md).

**1. Install the operator** from the mirrored catalog. `source` is the
`metadata.name` in `cs-*.yaml`. Wait for that catalog to be serving before
you subscribe:

```sh
# ===== RUN ON: THE CLUSTER (install side) =====
oc -n openshift-marketplace get catalogsource cs-redhat-operator-index-v4-21 \
  -o jsonpath='{.status.connectionState.lastObservedState}{"\n"}'   # READY

oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-update-service
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: update-service-operator-group
  namespace: openshift-update-service
spec:
  targetNamespaces:
    - openshift-update-service
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: update-service-subscription
  namespace: openshift-update-service
spec:
  channel: v1
  installPlanApproval: Automatic
  name: cincinnati-operator
  source: cs-redhat-operator-index-v4-21
  sourceNamespace: openshift-marketplace
EOF

oc -n openshift-update-service get csv     # wait for PHASE Succeeded
```

Subscribing before the catalog is `READY` can leave the operator stuck with
no CSV at all. The Subscription shows `ResolutionFailed` with
`connection refused`, and the catalog operator's log repeats
`failed to unpack bundles: jobs.batch "<hash>" already exists`. To recover,
delete that job and the ConfigMap with the same name in
`openshift-marketplace`, and OLM unpacks the bundle again:

```sh
# ===== RUN ON: THE CLUSTER (install side) =====
oc -n openshift-marketplace delete job <hash>
oc -n openshift-marketplace delete configmap <hash>
```

**2. Let OSUS trust the registry.** It pulls the graph-data image and reads
the release repository itself. The trust bundle in `install-config.yaml` does
not reach it. OSUS reads the key `updateservice-registry`, and image pulls by
the registry's `host:port` read a key written as `host..port`:

```sh
# ===== RUN ON: THE CLUSTER (install side) =====
oc -n openshift-config create configmap registry-config \
  --from-file=updateservice-registry=<bundle>/certs/rootCA.pem \
  --from-file=registry.airgap.local..8443=<bundle>/certs/rootCA.pem

oc patch image.config.openshift.io cluster --type merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"registry-config"}}}'
```

**3. Create the service.** The generated file has no namespace, so give it
one:

```sh
# ===== RUN ON: THE CLUSTER (install side) =====
oc apply -n openshift-update-service -f <bundle>/cluster-resources/updateService.yaml

oc -n openshift-update-service get updateservice update-service-oc-mirror \
  -o jsonpath='{.status.policyEngineURI}{"\n"}'     # empty until it is ready
```

`replicas: 2` in the generated file is fine on a single node. Both pods
schedule there.

**4. Point the cluster at it**, and set the channel to the one you mirrored.
The installer sets `stable-<minor>`, so a release you took from `fast-` is
not in the cluster's channel and no update path is found:

```sh
# ===== RUN ON: THE CLUSTER (install side) =====
PE=$(oc -n openshift-update-service get updateservice update-service-oc-mirror \
  -o jsonpath='{.status.policyEngineURI}')
echo "${PE:?not ready yet -- wait for step 3}"
oc patch clusterversion version --type merge -p \
  "{\"spec\":{\"channel\":\"<mirrored channel>\",\"upstream\":\"${PE}/api/upgrades_info/v1/graph\"}}"

oc adm upgrade      # Upstream: the route above; no CannotRetrieveUpdates
```

The `echo` stops the block when the URI is still empty. Without it, the
patch sets the upstream to a bare `/api/upgrades_info/v1/graph`, and
`RetrievedUpdates` fails with `unsupported protocol scheme ""`.

Expect a few minutes of `503 Service Unavailable` straight after this. The
OSUS pods have to finish building the graph, and the cluster version
operator polls only every few minutes, so it can go on reporting the 503
after the route already answers. Check the route directly if you want to
know which:

```sh
# ===== RUN ON: THE CLUSTER (install side) =====
curl -s --cacert <bundle>/certs/rootCA.pem -o /dev/null -w '%{http_code}\n' \
  "${PE}/api/upgrades_info/v1/graph?channel=<mirrored channel>"      # 200 when ready
```

The cluster version operator reaches that route over TLS, so it has to trust
the ingress certificate. That holds when ingress serves a certificate signed
by the CA in `additionalTrustBundle`. With the default self-signed ingress
certificate it does not hold, and you must add the ingress CA to the
`user-ca-bundle` ConfigMap in `openshift-config` first. Otherwise
`RetrievedUpdates` reports a certificate error.

`oc adm upgrade` lists only what is in the registry. Until a later mirror
adds a newer release, "No updates available" is the correct answer.

---

## Known limits to state explicitly

Write these down rather than letting them be discovered.

- Only the mirrored **architecture** can be installed.
- Only the mirrored **version** exists. Upgrading means another prep cycle —
  [09-day2-delta.md](09-day2-delta.md).
- Operators absent from `imageset-config.yaml` are **not installable**, and
  adding one means another airgap transfer.
- **CDI/DataVolume imports do not honour IDMS/ITMS.** If virtualization is in
  scope, the install side must point DataVolumes at the registry explicitly,
  disable operator-managed boot source imports, and supply the CA via
  `certConfigMap`. See
  [02-plan-your-content.md](02-plan-your-content.md#obligations-this-creates-for-the-install-side).
- **The registry is now infrastructure.** If the registry host goes
  away, the cluster cannot pull images. It needs the same care as any other
  production dependency.
- **Compliance auto-remediation reboots nodes.** If the Compliance Operator
  is in scope, recommend scan-only (`default`) before `default-auto-apply`.

---

## Handing over

Walk through [checklists/handoff-contract.md](https://github.com/bgregori/disconnected-prep/blob/main/checklists/handoff-contract.md)
with whoever is doing the install. It is short, and it converts the list
above into confirmed shared understanding rather than a directory someone
was emailed.

The questions worth asking directly:

1. Does `REGISTRY_HOST` resolve from the node network? Have they checked, or
   are they assuming?
2. Do they know `imageDigestSources` is mandatory?
3. Do they know which operators are available — and which are not?
4. Do they know who to come back to, and that adding content means another
   transfer window?

---

## Keeping prep reproducible

Retain on the registry host:

- `imageset-config.yaml` — required for Day-2
- `imports/<tag>/` — at least the most recent
- `config/prep.env` — your environment's parameters
- this repository

Retain on the connected bastion:

- `mirror-out/working-dir/.history/` — **deleting this means every future
  update is a full re-download**
- `cache/`
- `config/imageset-config.yaml`

---

Next: [09-day2-delta.md](09-day2-delta.md) — for when this cluster needs an
upgrade or a new operator.
