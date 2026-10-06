# Prerequisites

What must exist before you start. Read this before provisioning the
hosts — two of these are expensive to fix later.

Work this chapter top to bottom. It ends with the tooling installed, which
every later chapter assumes.

Preflight runs **twice**. The first pass checks the host itself and runs on
a bare, freshly provisioned host. The second comes after
[Install the tooling](#install-the-tooling) below.

```sh
cp config/prep.env.example config/prep.env
${EDITOR} config/prep.env

# first pass -- host posture, on a bare host
ROLE=connected    ./scripts/00-preflight.sh    # on the connected bastion
ROLE=disconnected ./scripts/00-preflight.sh    # on the registry host
```

On a bare host that first pass **exits non-zero**, reporting missing `oc`,
`oc-mirror` and pull secret. That is expected — every host check above them
has still run, and they are installed at the end of this chapter. It also
reports a missing ImageSetConfiguration, which stays missing until
[03-plan-your-content.md](03-plan-your-content.md); the run that must exit
clean is the one in
[04-connected-mirror.md](04-connected-mirror.md), immediately before
mirroring.

### Checking by hand

Without the repo, these are the checks that matter. They split the same way
the script does.

**Pass 1 — on a bare host.** Nothing here needs the tooling installed.

```sh
# --- OS and hardening posture ---
cat /etc/redhat-release
cat /proc/sys/crypto/fips_enabled           # 1 = host in FIPS mode
getenforce                                  # expect Enforcing
umask                                       # 0077 on a STIG build -- see docs/02
systemctl is-active fapolicyd firewalld

# --- oc-mirror's local storage port must be free ---
ss -ltn | grep -q ':55000 ' && echo "PORT 55000 IN USE" || echo "port 55000 free"

# --- disk ---
# ~/ocp-airgap does not exist yet, so check the filesystem it will land on.
df -h ~

# --- upstream reachable (connected host only) ---
# ANY three-digit code passes -- it means the server answered. Only 000 is
# a failure: no HTTP response at all (DNS, blocked egress, TLS, timeout).
# Typical healthy output is 404 / 200 / 302 respectively; registry.redhat.io
# serves nothing at / because its API is under /v2/.
for r in registry.redhat.io quay.io mirror.openshift.com; do
  printf '%-24s %s\n' "$r" "$(curl -s -o /dev/null -w '%{http_code}' -m 10 https://$r/)"
done

# Sharper check of the endpoint oc-mirror actually uses -- expect 401,
# the registry API demanding credentials:
curl -s -o /dev/null -w 'registry.redhat.io/v2/  %{http_code}\n' \
  -m 10 https://registry.redhat.io/v2/

# --- registry hostname must be fully qualified ---
# oc-mirror parses an unqualified docker:// target as a repository name.
# See "Naming and DNS" below -- resolve it from a cluster node, not here.
```

Reachability is not entitlement. These checks say the hosts answer, not
that your pull secret may pull from them — see
[Credentials](#credentials), and note that entitlement is only truly
proven when operator mirroring runs.

**Pass 2** needs the tooling and credentials to exist, so it comes after
[Install the tooling](#install-the-tooling) at the end of this chapter. The
checks are there, under
[Second preflight pass](#second-preflight-pass).

---

## The two hosts

| | Connected bastion | Registry host |
|---|---|---|
| Network | Internet, or a proxy to it | Airgapped, routable to cluster nodes |
| OS | RHEL 9 | RHEL 9 |
| vCPU | 4+ | 4+ |
| RAM | 16 GB | 16 GB |
| Disk | cache + archive output | Quay + imports + cache |
| Role | pull content, build archives | serve content to the cluster |

The registry host is airgapped — "registry host" names what it does rather
than what it lacks, which is the more useful label when what matters
operationally is which machine serves content and which one fetches it.

**Both hosts are permanent.** The registry host runs the mirror registry
the cluster depends on, during install and for the life of the cluster. The
connected bastion is the only way new content enters that registry: every
z-stream upgrade, added operator, and additional image is pulled and
archived there, against caches and history that have to survive between
runs — see [Day-2 delta updates](10-day2-delta.md). Treat both as
production from the start: back them up, and provision them on the
assumption that they stay.

> **Provisioning this with the `disconnected-install-sandbox` Ansible?**
> The names line up with its `sandbox_role` tags: `bastion` is the
> connected bastion, `registry` is the registry host. Note that its
> `bastion` is also the SSH jump host for everything else, and the registry
> host is reached through it by `ProxyCommand`.

### Disk, concretely

The most common prep failure is running out of space overnight.

On the **connected** bastion you need two full-size copies:

- **cache** (`CACHE_DIR`) — roughly the full uncompressed content set
- **archive output** (`MIRROR_OUT`) — the tar archives

They are not the same data and not deduplicated against each other. On the
same partition, budget double.

On the **registry host**:

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
| | **registry host total** | **84.8 GiB** |

Wall clock: 14m53s to mirror (7m pull, 8m tarball), 27m to push.

There is no maintenance window to plan around. These numbers are from a
first mirror, where no cluster exists yet and nothing is serving workloads.
Later delta runs against a built cluster are online too, since the pipeline
only adds content to the registry — see
[Day-2 delta updates](10-day2-delta.md). The timings are for scheduling the
run itself.

Three things worth internalising:

- The archive is *larger* than the cache, and building it took as long as
  the download. Estimating a run from download time alone halves the real
  figure.
- The **import directory is the biggest single consumer** on the
  disconnected side, because disk-to-mirror writes its `working-dir/` there
  alongside the archive.
- The registry host needed **~3.8× the deduplicated download** in
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
mirror. It must contain a `registry.redhat.io` key: that entitlement is
separate from `quay.io`, so a secret can succeed on the release payload and
still fail partway through operator mirroring with authentication errors.

Confirm the entitlement now, on the account you will use. You put the file
in place under [Install the tooling](#install-the-tooling) below, and check
its contents in the [second preflight pass](#second-preflight-pass).

---

## Naming and DNS

The registry hostname you choose goes into IDMS/ITMS and
`install-config.yaml`, and ends up baked into a running cluster. Changing it
later means re-pushing and re-applying cluster config.

Requirements:

- **Fully qualified.** `oc-mirror` parses an unqualified `docker://` target
  as a repository name, not a hostname. `bastion` fails; `bastion.airgap.local`
  works.
- **Resolvable from the cluster nodes**, not just from the registry host. An
  `/etc/hosts` entry on the registry host is the classic trap: mirroring succeeds
  and the install hangs at bootstrap.
- **Stable.** Prefer a DNS name you control over an IP.

Verify from somewhere that is not the registry host, before you mirror:

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

## Software on both hosts

`00-preflight.sh` checks for these.

| Tool | Where | Notes |
|---|---|---|
| `oc` | both | below on connected; arrives by transfer on disconnected |
| `oc-mirror` | both | v2; same channel as the payload |
| `mirror-registry` | disconnected | the Quay installer bundle; arrives by transfer |
| `podman` | disconnected | **must already be installed** — `mirror-registry` requires it and does not supply it |
| `curl`, `tar`, `sha256sum` | both | base install |
| `python3` | both | used by the compose/estimate scripts |
| `jq` | optional | nicer preflight validation |
| `tmux` | recommended | multi-hour runs |

No internet access is assumed on the registry host for any of this —
`30-package-transfer.sh` carries the tooling across on the first transfer,
and [06-registry.md](06-registry.md) stages it into place on arrival.

> Install `podman` on the registry host while it can still reach a
> package source, or from the RHEL media. `06-registry.md` queries it
> *before* installing Quay, to decide where image data will land.

---

## Install the tooling

> **Connected bastion.** On the registry host the same binaries
> arrive with the first transfer instead — see
> [06-registry.md](06-registry.md).

```sh
./scripts/10-fetch-binaries.sh
```

### By hand

```sh
mkdir -p ~/ocp-airgap/{binaries,config,cache,mirror-out,exports}
cd ~/ocp-airgap/binaries

base=https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-4.21

curl -fLO ${base}/openshift-client-linux.tar.gz
curl -fLO ${base}/oc-mirror.rhel9.tar.gz
curl -fLO https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/mirror-registry/1.3.9/mirror-registry.tar.gz
```

Pull `oc-mirror` from the **same channel as your payload**, not from
`clients/ocp/latest`. A newer `oc-mirror` can write archive metadata that
the version-matched tooling on the other side does not expect.

`mirror-registry.tar.gz` is downloaded here even though it is only used on
the registry host — this is the host with internet access, and
`30-package-transfer.sh` carries it across.

```sh
sudo tar -xzf openshift-client-linux.tar.gz -C /usr/local/bin oc
sudo tar -xzf oc-mirror.rhel9.tar.gz -C /usr/local/bin oc-mirror
sudo chown root:root /usr/local/bin/oc /usr/local/bin/oc-mirror
sudo chmod 0755 /usr/local/bin/oc /usr/local/bin/oc-mirror
```

> ⚠️ **STIG** On a hardened host these binaries will not execute yet.
> Relabel for SELinux, then add to the fapolicyd allowlist:
> ```sh
> sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror
> sudo fapolicyd-cli --file add /usr/local/bin/oc
> sudo fapolicyd-cli --file add /usr/local/bin/oc-mirror
> sudo fapolicyd-cli --update
> ```
> Order matters — relabelling changes the file, so trust it afterwards.
> See [02-fips-stig-rhel9.md](02-fips-stig-rhel9.md).

### Place the pull secret

Download it from
<https://console.redhat.com/openshift/downloads> (bottom of the downloads
list), then:

```sh
cp ~/Downloads/pull-secret.json ~/ocp-airgap/binaries/pull-secret.json
chmod 600 ~/ocp-airgap/binaries/pull-secret.json
```

> ⚠️ **STIG** Connected bastion only. Do not carry it across the airgap.

---

## Second preflight pass

Everything above now exists, so these checks can run. The
ImageSetConfiguration is the one remaining gap, and
[03-plan-your-content.md](03-plan-your-content.md) fills it.

```sh
ROLE=connected ./scripts/00-preflight.sh
```

### By hand

```sh
# --- tooling actually executes (fapolicyd blocks unlisted binaries) ---
oc version --client
( umask 0022; oc-mirror version --v2 >/dev/null && echo "oc-mirror OK" )

# --- disk, on the filesystems that actually fill up ---
df -h ~/ocp-airgap/cache          # layer cache
df -h ~/ocp-airgap/mirror-out     # archives

# --- credentials ---
jq -e '.auths["registry.redhat.io"]' ~/ocp-airgap/binaries/pull-secret.json \
  >/dev/null && echo "pull secret has registry.redhat.io"
```

On the **registry host** the equivalent checks belong after the
transfer has been staged — [06-registry.md](06-registry.md) runs them
there, including the `podman info` storage check that only makes sense on
that host.

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
