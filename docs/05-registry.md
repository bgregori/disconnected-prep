# Mirror registry

On the **registry host**. Installs Red Hat `mirror-registry`
(standalone Quay), trusts its CA, and writes the auth file used for the
push.

```sh
# ===== RUN ON: REGISTRY HOST =====
./scripts/40-stage-transfer.sh                # first transfer only
ROLE=disconnected ./scripts/00-preflight.sh
./scripts/50-install-registry.sh
```

Already have an enterprise registry? See
[appendix-byo-registry.md](appendix-byo-registry.md) and skip this chapter.

---

## Stage the transferred tooling

**First transfer only.** Everything arrived under `imports/<tag>/`, but the
rest of this chapter — and `50-install-registry.sh` — expects the prep tree
layout at `${OCP_AIRGAP_ROOT}/`. Put it in place before anything else:

```sh
# ===== RUN ON: REGISTRY HOST =====
: "${OCP_AIRGAP_ROOT:?set it first -- see 01-prerequisites.md}"
TAG=2026-10-02_initial

mkdir -p ${OCP_AIRGAP_ROOT}/{binaries,config,cache}
cp ${OCP_AIRGAP_ROOT}/imports/${TAG}/binaries/* ${OCP_AIRGAP_ROOT}/binaries/
```

Then install `oc` and `oc-mirror` on *this* host:

```sh
# ===== RUN ON: REGISTRY HOST =====
cd ${OCP_AIRGAP_ROOT}/binaries
sudo tar -xzf openshift-client-linux.tar.gz -C /usr/local/bin oc
sudo tar -xzf oc-mirror.rhel9.tar.gz -C /usr/local/bin oc-mirror
sudo chown root:root /usr/local/bin/oc /usr/local/bin/oc-mirror
sudo chmod 0755 /usr/local/bin/oc /usr/local/bin/oc-mirror

sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror
sudo fapolicyd-cli --file add /usr/local/bin/oc
sudo fapolicyd-cli --file add /usr/local/bin/oc-mirror
sudo fapolicyd-cli --update
```

> ⚠️ **STIG** The fapolicyd allowlist is per-host. Doing this on the
> connected bastion did nothing for this one.

Verify, then run preflight — which checks for `oc` and `oc-mirror` and
fails without them:

```sh
# ===== RUN ON: REGISTRY HOST =====
oc version --client
( umask 0022; oc-mirror version --v2 >/dev/null && echo "oc-mirror OK" )

ROLE=disconnected ./scripts/00-preflight.sh
```

`podman` must already be present; `mirror-registry` requires it and does
not install it. The next section queries it before Quay exists.

---

## Before you start

Set in `config/prep.env`:

```sh
# ===== EDIT IN: config/prep.env on the REGISTRY HOST =====
REGISTRY_HOST="registry.airgap.local"  # FQDN, resolvable from cluster nodes
REGISTRY_PORT="8443"
QUAY_ROOT="/opt/quay"                  # megabytes, not the image store
QUAY_USER="init"
QUAY_PASSWORD="<at least 8 characters>"
```

> ### ⚠️ `--quayRoot` is **not** where the images go
>
> This trips up almost everyone, and the usual advice — "point `--quayRoot`
> at a partition with 500 GB" — is wrong.
>
> `--quayRoot` holds configuration and certificates only. Measured on a real
> install: **8 files, 32 KB.**
>
> The image data goes into a **podman named volume** called `quay-storage`,
> under podman's storage root:
>
> ```
> ~/.local/share/containers/storage/volumes/quay-storage/_data
> ```
>
> which lives on whatever filesystem holds `$HOME` — typically `/`.
>
> Provision a large `/data`, point `--quayRoot` at it, and you will still
> fill up the root filesystem and take the registry down.
>
> **Check where it will actually land, before installing:**
>
> ```sh
> podman info --format '{{.Store.VolumePath}}'
> df -h "$(podman info --format '{{.Store.GraphRoot}}')"
> ```
>
> **To put image storage on a big volume**, configure podman *before*
> running the installer:
>
> ```sh
> mkdir -p ~/.config/containers
> sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 0755 /data/containers/storage
> cat > ~/.config/containers/storage.conf <<'EOF'
> [storage]
> driver = "overlay"
> graphroot = "/data/containers/storage"
> EOF
> podman info --format '{{.Store.GraphRoot}}'   # confirm before installing
> ```
>
> ⚠️ **STIG Relabel it for SELinux, or the containers cannot read their
> own storage.** A freshly provisioned `/data` has no file context rule, so
> everything written there lands as `default_t` instead of the
> `container_*` types the container runtime expects. Teach SELinux that the
> new path is equivalent to the default one, *before* populating it:
>
> ```sh
> sudo semanage fcontext -a -e /var/lib/containers /data/containers/storage
> sudo restorecon -Rv /data/containers/storage
> ```
>
> Skipping this produces permission errors from inside the Quay containers
> that name a file the host can plainly read — see
> [the appendix](appendix-fips-stig.md#selinux-mislabels-extracted-binaries)
> for the same failure in its other form. Check with
> `ls -Zd /data/containers/storage`, and `sudo ausearch -m AVC -ts recent`
> when something fails anyway.
>
> Do this first. Moving it after Quay holds data means re-pushing
> everything.
>
> **Confirm podman actually resolved it**, because a `storage.conf`
> pointing at a directory the invoking user cannot write is worse than no
> `storage.conf` at all — Quay's pod is created and its containers never
> start, which the installer reports as a timeout polling
> `/health/instance` rather than as a storage problem:
>
> ```sh
> podman info --format '{{.Store.GraphRoot}}'   # /data/containers/storage
> ls -ld /data/containers/storage               # owned by you, not root
> ```
>
> `scripts/00-preflight.sh` checks the real storage path, not `QUAY_ROOT`.

`QUAY_ROOT` still needs to be on durable storage — it holds the CA and the
TLS keys — but it needs megabytes, not hundreds of gigabytes. Remember this
host is infrastructure the cluster depends on for the life of the cluster.

---

## Unpack and install

```sh
# ===== RUN ON: REGISTRY HOST =====
cd ${OCP_AIRGAP_ROOT}/binaries
tar -xzf mirror-registry.tar.gz

sudo firewall-cmd --add-port 8443/tcp --permanent
sudo firewall-cmd --reload

# Quay runs as USER systemd services. Enable lingering BEFORE installing --
# see below.
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" | grep Linger       # expect Linger=yes

# QUAY_ROOT must exist and be yours before the installer runs -- see below
sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 0755 /opt/quay

umask 0022 && ./mirror-registry install \
  --quayHostname registry.airgap.local \
  --quayRoot /opt/quay \
  --initUser init \
  --initPassword '<password>'
```

> ⚠️ **Create `--quayRoot` yourself first.** `mirror-registry` drives an
> embedded Ansible playbook as the invoking user, and that user cannot
> create a directory in a root-owned parent like `/opt`. The install dies
> a dozen tasks in with
>
> ```
> There was an issue creating /opt/quay as requested:
> [Errno 13] Permission denied: b'/opt/quay'
> ```
>
> `install -d` rather than `mkdir`, for the usual two reasons: `sudo` for
> the root-owned parent with the directory handed to the account that runs
> the installer, and an explicit `0755` instead of the STIG `umask 0077`,
> which would hand Quay a `0700` directory and trade this failure for the
> crash-loop below.
>
> The same root-owned parent makes `mirror-registry uninstall` end on
> `rmtree failed: [Errno 13] Permission denied: '/opt/quay'` and exit 2.
> Everything inside was removed — deleting the directory *entry* needs
> write permission on `/opt`, which you deliberately do not have. The
> empty directory it leaves is the one the next install wants, so there is
> nothing to repair.

> ⚠️ **Enable lingering before the install, not after.** Quay runs as
> **user** systemd services, and `mirror-registry` starts them over its own
> SSH session to localhost. With `Linger=no`, systemd tears the user
> manager down with that session: the pod is created, its containers never
> start, and the installer fails ten polls later on
>
> ```
> Status code was -1 and not [200]: Request failed:
> <urlopen error TLS/SSL connection has been closed (EOF)>
> ```
>
> against `/health/instance` — which looks like a certificate problem and
> is not one. `podman ps -a` showing a lone `*-infra` container in
> `Created`, with no `quay-app`, is the tell. The same missing linger makes
> `mirror-registry uninstall` exit 2, so the failed install is awkward to
> clean up as well.
>
> Lingering is also what keeps the registry running after you log out —
> including while a cluster depends on it — so it is not merely an install
> step.

> ⚠️ **STIG — the `umask 0022` prefix is required.** With the STIG default
> of `0077`, the installer creates `quay-config` and `quay-rootCA` as `0700`
> and the Quay container — running as a different UID — cannot read them.
> The install reports success and the containers then crash-loop with
> `Permission denied` on `config.yaml`.

### Make the permission fix durable

The installer is not the only thing that writes those directories; restarts
and upgrades recreate them under whatever umask is in effect.

```sh
# ===== RUN ON: REGISTRY HOST =====
mkdir -p ~/.config/systemd/user/quay-app.service.d
cat > ~/.config/systemd/user/quay-app.service.d/fix-perms.conf <<'EOF'
[Service]
ExecStartPre=/bin/bash -c 'chmod -R 755 /opt/quay/quay-config /opt/quay/quay-rootCA; chmod 644 /opt/quay/quay-config/* /opt/quay/quay-rootCA/*'
EOF

systemctl --user daemon-reload
systemctl --user restart quay-app.service
```

> **Create this after the install, not before.** The drop-in applies to a
> unit that `mirror-registry install` creates. Written first, `daemon-reload`
> has nothing to attach it to and silently does nothing — which looks
> identical to it working.
>
> Paths in the drop-in must match your actual `QUAY_ROOT`. Guides that use
> `/data/quay` while installing to `/opt/quay` produce a drop-in that
> quietly does nothing.

---

## Trust the CA

`mirror-registry` generates a self-signed CA. `oc-mirror` reads TLS trust
from the **host trust store** — there is no per-command certificate flag.

```sh
# ===== RUN ON: REGISTRY HOST =====
sudo cp -v /opt/quay/quay-rootCA/rootCA.pem \
           /etc/pki/ca-trust/source/anchors/quay-rootCA.pem
sudo update-ca-trust
```

Verify — this must succeed without `-k`:

```sh
# ===== RUN ON: REGISTRY HOST =====
curl -I https://registry.airgap.local:8443/v2/
```

> Do not reach for `--insecure` or `--dest-tls-verify=false`. It hides a
> broken trust chain that the cluster hits later, when diagnosis is far
> harder. In an accredited environment, disabled TLS verification in a build
> transcript is itself a finding.

📌 **Handoff** `rootCA.pem` is needed by the install side for
`additionalTrustBundle` in `install-config.yaml`. `90-handoff.sh` collects
it.

---

## Create the auth file

```sh
# ===== RUN ON: REGISTRY HOST =====
QUAY_AUTH=$(printf 'init:%s' '<password>' | base64 -w0)
cat > ${OCP_AIRGAP_ROOT}/binaries/mirror-pull-secret.json <<EOF
{"auths":{"registry.airgap.local:8443":{"auth":"${QUAY_AUTH}"}}}
EOF
chmod 600 ${OCP_AIRGAP_ROOT}/binaries/mirror-pull-secret.json
```

The key must exactly match the `docker://` target you push to, port
included. `registry.airgap.local` and `registry.airgap.local:8443` are
different keys and a mismatch produces an authentication failure that looks
like a credentials problem.

Verify:

```sh
# ===== RUN ON: REGISTRY HOST =====
printf '%s' '<password>' | podman login \
  --username init --password-stdin \
  --authfile ${OCP_AIRGAP_ROOT}/binaries/mirror-pull-secret.json \
  registry.airgap.local:8443
```

Pass `--username` and `--password-stdin` explicitly. Without them `podman
login` falls back to an **interactive prompt** when the stored credentials
are not accepted — which hangs any non-interactive run, and reports the
hang as `reading username: EOF` rather than as an auth problem.

> ⚠️ **Wait for Quay before verifying.** `mirror-registry install` prints
> `Quay installed successfully` as soon as the containers start, but Quay
> needs another one to three minutes to finish initialising — longer on a
> small host. Logging in during that window fails with
> `Existing credentials are invalid`, which looks like a credentials bug and
> is not one.
>
> Measured on a 2 vCPU / 7 GB RHEL 9.6 host: the health endpoint returned
> 502, then 503, then 200 roughly 80 seconds after the installer exited.
>
> ```sh
> until curl -s -o /dev/null -w '%{http_code}' \
>         https://registry.airgap.local:8443/health/instance | grep -q 200; do
>   sleep 5
> done
> ```
>
> `scripts/50-install-registry.sh` polls for this automatically.

Quay's startup logs contain `AssertionError` tracebacks from `gevent`.
These are normal noise, not a failure.

---

## Verify from somewhere else

The registry working on the registry host proves very little. The cluster nodes
are what matter.

```sh
# ===== RUN ON: A NODE-NETWORK HOST (not the registry host) =====
# from a host on the node network -- NOT the registry host
dig +short registry.airgap.local
curl -I https://registry.airgap.local:8443/v2/
```

If this fails, fix it now. The symptom later is an agent-based install that
hangs at bootstrap with no obvious cause.

---

## Operating notes

| | |
|---|---|
| Web UI | `https://registry.airgap.local:8443` |
| Service | `systemctl --user status quay-app` |
| Logs | `podman logs quay-app` |
| Storage | `du -sh /opt/quay` |
| Restart | `systemctl --user restart quay-app` |

Rotate `QUAY_PASSWORD` after the evaluation and regenerate the auth file.
The initial password appears in your shell history and in this repo's
config file.

---

Next: [06-push-to-registry.md](06-push-to-registry.md)
