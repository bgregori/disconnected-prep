# Handoff

The boundary. Prep produces a bundle; the install side consumes it.

```sh
./scripts/90-handoff.sh
```

Writes `~/ocp-airgap/handoff/<EXPORT_TAG>/`.

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
| `bin/openshift-install-fips` | ISO generation; required when `fips: true` |
| `imageset-config.yaml` | the record of what exists; required for every Day-2 update |

### Facts

- **Registry endpoint** — `https://<host>:<port>`
- **Release payload reference** — `<registry>/openshift/release-images:<version>-<arch>`
- **What is installable** — the operator list, and by implication what is not
- **What is not mirrored** — architectures, versions, operators deliberately excluded

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

### Building `imageDigestSources` by hand

`scripts/90-handoff.sh` generates this, but you do not need it. The entries
in the generated IDMS are **already the right shape** — `imageDigestSources`
takes a list of `{source, mirrors}` maps, and YAML maps are unordered, so
the `mirrors:`-before-`source:` ordering oc-mirror emits is fine as-is.

Open the generated IDMS:

```sh
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
[02-fips-stig-rhel9.md](02-fips-stig-rhel9.md)):

```sh
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
grep -c '^\s*- mirrors:' <import-dir>/working-dir/cluster-resources/idms-oc-mirror.yaml
grep -c '^- mirrors:'     install-config.yaml
```

### `additionalTrustBundle` by hand

The registry CA, indented by two spaces under a literal block:

```sh
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
echo "pullSecret: '$(cat /path/to/mirror-pull-secret.json)'"
```

---

## After the install completes

```sh
oc apply -f cluster-resources/

oc patch operatorhub cluster --type merge \
  -p '{"spec":{"disableAllDefaultSources":true}}'
```

The last command disables the default catalog sources, which point at
`registry.redhat.io` and will fail indefinitely in a disconnected
environment, producing persistent degraded conditions.

> **Applying IDMS/ITMS triggers a rolling restart of every node** as the
> machine config operator rewrites the CRI-O configuration. On a
> single-node cluster that is a full API outage of several minutes. Expect
> it; do not interrupt it.

---

## Known limits to state explicitly

Write these down rather than letting them be discovered.

- Only the mirrored **architecture** can be installed.
- Only the mirrored **version** exists. Upgrading means another prep cycle —
  [10-day2-delta.md](10-day2-delta.md).
- Operators absent from `imageset-config.yaml` are **not installable**, and
  adding one means another airgap transfer.
- **CDI/DataVolume imports do not honour IDMS/ITMS.** If virtualization is in
  scope, the install side must point DataVolumes at the registry explicitly,
  disable operator-managed boot source imports, and supply the CA via
  `certConfigMap`. See
  [03-plan-your-content.md](03-plan-your-content.md#obligations-this-creates-for-the-install-side).
- **The registry is now infrastructure.** If the registry host goes
  away, the cluster cannot pull images. It needs the same care as any other
  production dependency.
- **Compliance auto-remediation reboots nodes.** If the Compliance Operator
  is in scope, recommend scan-only (`default`) before `default-auto-apply`.

---

## Handing over

Walk through [checklists/handoff-contract.md](../checklists/handoff-contract.md)
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

Next: [10-day2-delta.md](10-day2-delta.md) — for when this cluster needs an
upgrade or a new operator.
