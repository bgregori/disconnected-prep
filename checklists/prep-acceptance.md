# Prep acceptance checklist

Complete before handing anything to the install team.

`./scripts/80-verify-mirror.sh` covers the automated items. The rest need a
person.

Environment: ______________________  Date: ____________  By: ____________

---

## Planning

- [ ] Exact OpenShift version pinned (`minVersion == maxVersion`)
- [ ] Architecture(s) confirmed against the target hardware
- [ ] Every operator anyone will need is in `imageset-config.yaml`
- [ ] Diagnostics mirrored (`support-tools`, `must-gather`)
- [ ] If virtualization: guest boot sources chosen
- [ ] If Windows guests: `virtio-win` included
- [ ] `imageset-config.yaml` stored somewhere durable
- [ ] Someone other than the author has reviewed the operator list

## Connected bastion

- [ ] `ROLE=connected ./scripts/00-preflight.sh` passes
- [ ] Red Hat pull secret present, contains `registry.redhat.io`
- [ ] Cache is **not** under `$HOME` on a small partition
- [ ] Dry run reviewed — no missing or unexpected content
- [ ] Mirror completed without error
- [ ] `mirror-out/working-dir/.history/` exists and is protected

## Transfer

- [ ] `SHA256SUMS` generated before transfer
- [ ] Verified on arrival with `sha256sum -c`
- [ ] Red Hat pull secret **not** carried across
- [ ] Source export retained on the connected bastion

## Disconnected bastion

- [ ] **500 GB provisioned** on the filesystem podman actually uses
      (`df -h "$(podman info --format '{{.Store.GraphRoot}}')"`), not on `--quayRoot`
- [ ] `ROLE=disconnected ./scripts/00-preflight.sh` passes
- [ ] `oc` / `oc-mirror` execute (SELinux relabelled, fapolicyd allowlisted)
- [ ] Registry installed and running
- [ ] `loginctl enable-linger` set — survives logout
- [ ] Permission drop-in in place, paths match the real `QUAY_ROOT`
- [ ] CA in the system trust store; `curl` succeeds without `-k`
- [ ] Auth file key exactly matches the push target, port included
- [ ] Push completed without error

## Verification

- [ ] `./scripts/80-verify-mirror.sh` exits clean
- [ ] Registry API reachable over TLS
- [ ] Release payload present and readable
- [ ] `openshift-install-fips` extracted, version matches
- [ ] IDMS / ITMS / CatalogSource / signatures generated
- [ ] Catalog images pullable
- [ ] Additional images spot-checked
- [ ] **Registry resolves and responds from the node network, not just the bastion**
- [ ] Registry has headroom for Day-2 growth

## Environment readiness (confirmed, not configured)

- [ ] `api.<cluster>.<base-domain>` resolves from the node network
- [ ] `*.apps.<cluster>.<base-domain>` resolves from the node network
- [ ] NTP reachable from the node network
- [ ] Nodes can reach `REGISTRY_HOST:REGISTRY_PORT`
- [ ] Out-of-band management reachable, virtual media available

## Handoff

- [ ] `./scripts/90-handoff.sh` run; bundle complete
- [ ] `install-config-fragment.yaml` contains real `imageDigestSources`
- [ ] Bundle `README.md` reviewed for accuracy
- [ ] [handoff-contract.md](handoff-contract.md) walked through with the
      install team
- [ ] Known limits stated explicitly, including CDI/IDMS if virtualization
      is in scope

---

## Sign-off

Prep complete and verified.

Name: ______________________  Date: ____________

Received by: ______________________  Date: ____________
