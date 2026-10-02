# Prerequisites

What must exist before you start. Read this before provisioning the
bastions — two of these are expensive to fix later.

```sh
cp config/prep.env.example config/prep.env
${EDITOR} config/prep.env

ROLE=connected    ./scripts/00-preflight.sh    # on the connected bastion
ROLE=disconnected ./scripts/00-preflight.sh    # on the disconnected bastion
```

### Checking by hand

Without the repo, these are the checks that matter. Run them on both
bastions before starting.

```sh
# --- OS and hardening posture ---
cat /etc/redhat-release
cat /proc/sys/crypto/fips_enabled           # 1 = bastion in FIPS mode
getenforce                                  # expect Enforcing
umask                                       # 0077 on a STIG build -- see docs/02
systemctl is-active fapolicyd firewalld

# --- tooling actually executes (fapolicyd blocks unlisted binaries) ---
oc version --client
( umask 0022; oc-mirror version --v2 >/dev/null && echo "oc-mirror OK" )

# --- oc-mirror's local storage port must be free ---
ss -ltn | grep -q ':55000 ' && echo "PORT 55000 IN USE" || echo "port 55000 free"

# --- disk, on the filesystems that actually fill up ---
df -h "$(dirname ~/ocp-airgap/cache)"       # cache
df -h "$(dirname ~/ocp-airgap/mirror-out)"  # archives
# disconnected host only -- where Quay really stores images:
df -h "$(podman info --format '{{.Store.GraphRoot}}')"

# --- credentials (connected host only) ---
jq -e '.auths["registry.redhat.io"]' ~/ocp-airgap/binaries/pull-secret.json \
  >/dev/null && echo "pull secret has registry.redhat.io"

# --- upstream reachable (connected host only) ---
for r in registry.redhat.io quay.io mirror.openshift.com; do
  printf '%-24s %s\n' "$r" "$(curl -s -o /dev/null -w '%{http_code}' -m 10 https://$r/)"
done

# --- registry hostname must be fully qualified ---
# oc-mirror parses an unqualified docker:// target as a repository name.
```

---

## The two bastions

| | Connected | Disconnected |
|---|---|---|
| Network | Internet, or a proxy to it | Airgapped, routable to cluster nodes |
| OS | RHEL 9 | RHEL 9 |
| vCPU | 4+ | 4+ |
| RAM | 16 GB | 16 GB |
| Disk | cache + archive output | Quay + imports + cache |
| Role | pull content, build archives | serve content to the cluster |

The disconnected bastion is not a scratch host. It runs the mirror registry
that the cluster depends on, during install and for the life of the cluster.
Treat it as production from the start: back it up, and do not plan to
repurpose it after the evaluation.

### Disk, concretely

The most common prep failure is running out of space overnight.

On the **connected** bastion you need two full-size copies:

- **cache** (`CACHE_DIR`) — roughly the full uncompressed content set
- **archive output** (`MIRROR_OUT`) — the tar archives

They are not the same data and not deduplicated against each other. On the
same partition, budget double.

On the **disconnected** bastion:

- **podman's storage root** — where the registry images actually live,
  ~1.3× the archive size
- **`IMPORTS_DIR`** — the transferred archives
- **`CACHE_DIR`** — oc-mirror's working cache during the push (the archive
  is extracted here before being pushed, so it needs roughly the full
  archive size again)
- **`QUAY_ROOT`** — config and certificates only. Megabytes.

> ⚠️ **`QUAY_ROOT` is not where the images go.** `mirror-registry
> --quayRoot` sets the *configuration* directory — measured at 32 KB on a
> real install. Image data goes to a podman volume under
> `~/.local/share/containers/storage/`, i.e. whatever filesystem holds
> `$HOME`.
>
> Sizing `--quayRoot` instead of podman's storage root is the most common
> way to run a disconnected registry out of disk. Check before installing:
>
> ```sh
> df -h "$(podman info --format '{{.Store.GraphRoot}}')"
> ```
>
> [06-registry.md](06-registry.md) shows how to relocate it.

Rough starting points, for a single x86_64 z-stream:

| Content | Cache | Archive | Quay |
|---|---|---|---|
| Platform only | 25–35 GB | 25–35 GB | 40 GB |
| + 2–3 small operators | 30–50 GB | 30–50 GB | 70 GB |
| + Virtualization & guest images | 150–300 GB | 150–300 GB | 400 GB |
| + ACS, ODF, large operator set | 400–800 GB | 400–800 GB | 1 TB |

**Measured anchor.** OpenShift 4.21.34 platform + `compliance-operator` +
`file-integrity-operator` + 3 diagnostic images — 202 images, 22.4 GiB
deduplicated — run end to end on RHEL 9.6:

| Where | What | Measured |
|---|---|---|
| connected | cache (`--cache-dir`) | 25.4 GiB |
| connected | archive (`mirror_000001.tar`) | 28.5 GiB |
| connected | export dir (archive + binaries) | 29.3 GiB |
| disconnected | import dir (archive + d2m working-dir) | **32.6 GiB** |
| disconnected | extraction cache | 25.2 GiB |
| disconnected | registry storage (podman graphroot) | 27.0 GiB |
| | **connected host total** | **53.9 GiB** |
| | **disconnected host total** | **84.8 GiB** |

Wall clock: 14m53s to mirror (7m pull, 8m tarball), 27m to push.

Three things worth internalising:

- The archive is *larger* than the cache, and building it took as long as
  the download. Both matter for a maintenance window.
- The **import directory is the biggest single consumer** on the
  disconnected side, because disk-to-mirror writes its `working-dir/` there
  alongside the archive.
- The disconnected bastion needed **~3.8× the deduplicated download** in
  total, since imports, cache and registry all coexist. Plan for ~4.5×.

> The numbers above size the **first** mirror. A registry that will run for
> years needs a different conversation — each retained OpenShift version
> adds ~19 GiB, and nothing is ever reclaimed automatically. See
> [11-capacity-planning.md](11-capacity-planning.md) before provisioning
> disks you cannot easily grow.

Operator size varies enormously — the two compliance operators above added
only a few GB, whereas virtualization with guest images adds hundreds.
Rather than size per-configuration, provision the standard **500 GB** and
check it against the marginal costs in
[11-capacity-planning.md](11-capacity-planning.md) if your content set is
unusual.

> `/var/lib/containers` also grows during the push. On a STIG'd build `/var`
> is frequently a separate, modest partition. Check it.

---

## Credentials

A Red Hat pull secret with entitlements for the content you intend to
mirror. Download from
<https://console.redhat.com/openshift/downloads> — it is at the **bottom**
of the downloads list, not with the binaries.

```sh
jq -e '.auths["registry.redhat.io"]' ~/ocp-airgap/binaries/pull-secret.json
```

If that key is absent, operator mirroring fails partway through with
authentication errors. `registry.redhat.io` entitlement is separate from
`quay.io` — a secret can succeed on the release payload and fail on
operators.

> ⚠️ **STIG** Connected bastion only. Do not carry it across the airgap.

---

## Naming and DNS

The registry hostname you choose goes into IDMS/ITMS and
`install-config.yaml`, and ends up baked into a running cluster. Changing it
later means re-pushing and re-applying cluster config.

Requirements:

- **Fully qualified.** `oc-mirror` parses an unqualified `docker://` target
  as a repository name, not a hostname. `bastion` fails; `bastion.airgap.local`
  works.
- **Resolvable from the cluster nodes**, not just from the bastion. An
  `/etc/hosts` entry on the bastion is the classic trap: mirroring succeeds
  and the install hangs at bootstrap.
- **Stable.** Prefer a DNS name you control over an IP.

Verify from somewhere that is not the bastion, before you mirror:

```sh
dig +short bastion.airgap.local
curl -I https://bastion.airgap.local:8443/v2/
```

---

## Target environment readiness

Not this repo's job to configure, but prep is the last checkpoint before
anyone needs them. Confirm they exist and hand the answers over.

- [ ] **DNS** — `api.<cluster>.<base-domain>` and
      `*.apps.<cluster>.<base-domain>` resolve from the node network.
      Required even for a single-node cluster.
- [ ] **Time sync** — NTP reachable from the node network. Certificate
      validation fails on skew, and an airgapped network often has no
      working time source. This causes install failures that look like TLS
      errors.
- [ ] **Registry reachability** — nodes can reach the registry host on
      `REGISTRY_PORT`, through whatever firewalls sit between.
- [ ] **Out-of-band management** — iDRAC/iLO/IPMI reachable, with virtual
      media available for the agent ISO.
- [ ] **Static addressing** — IPs or reservations for the nodes.

Specifics belong to the install side; record what you confirmed in
[the handoff contract](../checklists/handoff-contract.md).

---

## Software on the bastions

`00-preflight.sh` checks for these.

| Tool | Where | Notes |
|---|---|---|
| `oc` | both | installed by `10-fetch-binaries.sh` |
| `oc-mirror` | both | v2; same channel as the payload |
| `mirror-registry` | disconnected | the Quay installer bundle |
| `podman` | disconnected | pulled in by mirror-registry |
| `curl`, `tar`, `sha256sum` | both | base install |
| `python3` | both | used by the compose/estimate scripts |
| `jq` | optional | nicer preflight validation |
| `tmux` | recommended | multi-hour runs |

No internet access is assumed on the disconnected bastion for any of this —
`30-package-transfer.sh` carries the tooling across on the first transfer.

---

## Decide before you mirror

Three decisions are expensive to revisit, because changing any of them means
another trip across the airgap.

1. **Exact OpenShift version.** A pinned z-stream, not a floating channel.
2. **Every operator you will install.** Including ones you are "probably"
   going to want. See [03-plan-your-content.md](03-plan-your-content.md).
3. **Architecture.** Each additional architecture roughly multiplies the
   payload.

---

Next: [02-fips-stig-rhel9.md](02-fips-stig-rhel9.md) — read before running
anything on a hardened host.
