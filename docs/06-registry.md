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
layout at `~/ocp-airgap/`. Put it in place before anything else:

```sh
# ===== RUN ON: REGISTRY HOST =====
TAG=2026-10-02_initial

mkdir -p ~/ocp-airgap/{binaries,config,cache}
cp ~/ocp-airgap/imports/${TAG}/binaries/* ~/ocp-airgap/binaries/
```

Then install `oc` and `oc-mirror` on *this* host:

```sh
# ===== RUN ON: REGISTRY HOST =====
cd ~/ocp-airgap/binaries
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
QUAY_ROOT="/opt/quay"                  # on a partition with 500 GB+
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
> mkdir -p ~/.config/containers /data/containers/storage
> cat > ~/.config/containers/storage.conf <<'EOF'
> [storage]
> driver = "overlay"
> graphroot = "/data/containers/storage"
> EOF
> podman info --format '{{.Store.GraphRoot}}'   # confirm before installing
> ```
>
> Do this first. Moving it after Quay holds data means re-pushing
> everything.
>
> `scripts/00-preflight.sh` checks the real storage path, not `QUAY_ROOT`.

`QUAY_ROOT` still needs to be on durable storage — it holds the CA and the
TLS keys — but it needs megabytes, not hundreds of gigabytes. Remember this
host is infrastructure the cluster depends on for the life of the cluster.

---

## Unpack and install

```sh
# ===== RUN ON: REGISTRY HOST =====
cd ~/ocp-airgap/binaries
tar -xzf mirror-registry.tar.gz

sudo firewall-cmd --add-port 8443/tcp --permanent
sudo firewall-cmd --reload

umask 0022 && ./mirror-registry install \
  --quayHostname registry.airgap.local \
  --quayRoot /opt/quay \
  --initUser init \
  --initPassword '<password>'
```

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

### Survive logout

Quay runs as a **user** service.

```sh
# ===== RUN ON: REGISTRY HOST =====
sudo loginctl enable-linger $USER
loginctl show-user $USER | grep Linger     # expect Linger=yes
```

Without this, the registry disappears when you log out — including while a
cluster is depending on it.

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
cat > ~/ocp-airgap/binaries/mirror-pull-secret.json <<EOF
{"auths":{"registry.airgap.local:8443":{"auth":"${QUAY_AUTH}"}}}
EOF
chmod 600 ~/ocp-airgap/binaries/mirror-pull-secret.json
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
  --authfile ~/ocp-airgap/binaries/mirror-pull-secret.json \
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

Next: [07-push-to-registry.md](07-push-to-registry.md)
