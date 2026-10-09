# Handoff contract

Work through this **together** — prep engineer and install engineer. It
takes about fifteen minutes and exists to turn a directory someone was sent
into confirmed shared understanding.

Environment: ______________________  Date: ____________

Prep: ______________________  Install: ______________________

---

## 1. What you are receiving

Bundle location: `________________________________`

- [ ] `install-config-fragment.yaml`
- [ ] `pull-secret.json`
- [ ] `certs/rootCA.pem`
- [ ] `cluster-resources/`
- [ ] `bin/openshift-install-fips`
- [ ] `bin/oc`
- [ ] `imageset-config.yaml`
- [ ] `README.md`
- [ ] `SHA256SUMS` verified

## 2. Facts

| | |
|---|---|
| Registry endpoint | `https://________________________` |
| OpenShift version | `________________` |
| Architecture | `________________` |
| Release payload | `________________________________` |

## 3. Before generating the ISO

Three requirements. Missing any one fails the install, and the errors do not
say so.

Plus one decision that is not an `install-config.yaml` field and so gets
missed: **boot-disk encryption**. It is a `MachineConfig` applied at the
manifest stage, and adding it later means reprovisioning every node.

- [ ] Disk encryption decided: TPM v2 ☐ · Tang/NBDE ☐ · both ☐ · none, accepted by ISSO ☐
- [ ] If Tang: servers reachable from the node network, thumbprints in hand
- [ ] If TPM v2: TPM 2.0 present and enabled in firmware on every node (vTPM on virtual nodes)

- [ ] **`fips: true`** in `install-config.yaml` (if FIPS is required)
- [ ] **`imageDigestSources`** pasted from the fragment
      → *the most commonly forgotten item; without it the bootstrap tries to
      reach the internet and hangs*
- [ ] **`additionalTrustBundle`** pasted from the fragment, with
      `additionalTrustBundlePolicy: Always`
- [ ] **`openshift-install-fips`** used, not the generic installer
- [ ] **The host generating the ISO is itself in FIPS mode**
      (`cat /proc/sys/crypto/fips_enabled` → `1`)
      → *required by Red Hat for a `fips: true` cluster, and independent of
      which binary you used*
- [ ] Registry hostname **resolves from the node network** — verified, not
      assumed

Confirm the last one now:

```sh
# ===== RUN ON: A NODE-NETWORK HOST (not the registry host) =====
# from a host on the node network
dig +short <registry-host>
curl -I https://<registry-host>:<port>/v2/
```

- [ ] Verified, by: ______________  from host: ______________

## 4. After the install

- [ ] `oc apply -f cluster-resources/`
- [ ] `oc apply -f cluster-resources/signatures/` (if present)
- [ ] `oc patch operatorhub cluster --type merge -p '{"spec":{"disableAllDefaultSources":true}}'`
- [ ] Understood: **applying IDMS/ITMS reboots every node.** On a
      single-node cluster that is a full outage.

## 5. What is available

Operators installable in this environment:

```
________________________________________________
________________________________________________
________________________________________________
```

- [ ] Install engineer has seen this list
- [ ] Understood: anything not listed requires another airgap transfer

## 6. Limits — state each one aloud

- [ ] Only architecture `__________` is mirrored
- [ ] Only version `__________` exists; upgrades need a prep cycle
- [ ] The registry is now **production infrastructure** — if the
      registry host goes away, the cluster cannot pull images
- [ ] Adding content requires a transfer window. Typical lead time:
      `__________`

### If virtualization is in scope

- [ ] Understood: **CDI does not honour IDMS/ITMS.** Boot source imports
      will fail unless DataVolumes point at the registry explicitly.
- [ ] Understood: operator-managed boot source import must be disabled
      (`enableCommonBootImageImport: false`)
- [ ] Understood: CDI needs the CA via `spec.source.registry.certConfigMap`;
      `additionalTrustBundle` does not cover it
- [ ] Windows guests planned? `virtio-win` mirrored: yes / no / n-a

### If compliance scanning is in scope

- [ ] Understood: `default-auto-apply` applies remediations as
      MachineConfigs, each rebooting nodes
- [ ] Agreed starting point: scan-only (`default`) / auto-apply

### If ACS is in scope

- [ ] Understood: offline vulnerability definitions are a separate,
      recurring import

## 7. Environment readiness

Confirmed by prep, owned by install:

- [ ] `api.<cluster>.<base-domain>` resolves
- [ ] `*.apps.<cluster>.<base-domain>` resolves
- [ ] NTP reachable — *skew causes failures that present as TLS errors*
- [ ] Out-of-band management and virtual media available

## 8. Escalation

| | |
|---|---|
| Prep contact | ______________________ |
| Registry owner | ______________________ |
| Transfer window process | ______________________ |
| Typical lead time | ______________________ |

---

## Sign-off

Handed over: ______________________  Date: ____________

Received, limits understood: ______________________  Date: ____________
