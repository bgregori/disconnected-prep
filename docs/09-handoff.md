# Handoff

The boundary. Prep produces a bundle; the install side consumes it.

```sh
./scripts/90-handoff.sh
```

Writes `~/ocp-airgap/handoff/<EXPORT_TAG>/`.

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

imageDigestSources:              # from install-config-fragment.yaml
  - source: quay.io/openshift-release-dev/ocp-release
    mirrors:
      - bastion.airgap.local:8443/openshift/release-images
  # ... remaining entries

additionalTrustBundle: |         # from install-config-fragment.yaml
  -----BEGIN CERTIFICATE-----
  ...
additionalTrustBundlePolicy: Always
```

**`imageDigestSources` is the one that gets forgotten.** Without it the
agent ISO attempts to reach `quay.io` during bootstrap. On an airgapped
network that means the install hangs rather than failing cleanly, and the
bootstrap logs do not make the cause obvious.

`additionalTrustBundlePolicy: Always` matters for `platform: none` — without
it the bundle may only be applied to proxy connections rather than to
registry pulls.

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
  [03-plan-your-content.md](03-plan-your-content.md#-obligations-this-creates-for-the-install-side).
- **The registry is now infrastructure.** If the disconnected bastion goes
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

Retain on the disconnected bastion:

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
