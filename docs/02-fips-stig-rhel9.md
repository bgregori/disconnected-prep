# FIPS and STIG on the RHEL 9 hosts

Everything in this chapter exists because these hosts are hardened. On a
stock RHEL 9 box none of it is necessary, which is why none of it appears in
the standard Red Hat mirroring documentation.

Each failure below is one that produces a misleading error. If you are
debugging something that "should obviously work", start here.

---

## First, a distinction

Two separate things get conflated constantly:

**Host FIPS mode** — whether the prep host itself boots with `fips=1`. It
affects which crypto the mirroring tools may use. It is *not* required for
mirroring: you can pull, archive, transfer and push from a non-FIPS host.

**Cluster FIPS mode** — `fips: true` in `install-config.yaml`. This is what
the accreditation actually cares about. It is set at install time and cannot
be changed afterwards.

The two are independent for everything in this repo except the last step.
A `fips: true` cluster has **two** requirements, and both are easy to miss
because neither fails loudly:

1. **A FIPS-capable installer binary** — `openshift-install-fips`,
   extracted from the release payload. The generic `openshift-install` will
   not do. See [08-verify.md](08-verify.md).
2. **A host in FIPS mode to run it on.** Red Hat requires the installation
   program to run from a RHEL 9 computer configured to operate in FIPS
   mode. Generating the agent ISO on a host with `fips_enabled=0` is not a
   supported configuration for a FIPS cluster, whichever binary you used.

Only the second is a *host* requirement, and it applies to whichever
machine runs `openshift-install-fips` — not to the connected bastion, and
not to the registry host unless you generate the ISO there. Extracting the
binary is just `oc adm release extract` and needs no FIPS host.

```sh
cat /proc/sys/crypto/fips_enabled   # must be 1 on the ISO-generating host
```

Red Hat's statement of the requirement:
<https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installation_overview/installing-fips>

---

## fapolicyd blocks binaries you just installed

**Symptom**

```
$ oc version
bash: /usr/local/bin/oc: Operation not permitted
```

Permissions look correct. You are root. It still fails.

**Cause**

STIG requires application allowlisting (`RHEL-09-433010` and related).
`fapolicyd` denies execution of any binary not in a trust database. A file
you just extracted from a tarball is, by definition, not in it.

**Fix**

```sh
sudo fapolicyd-cli --file add /usr/local/bin/oc
sudo fapolicyd-cli --file add /usr/local/bin/oc-mirror
sudo fapolicyd-cli --update
```

`--update` is required; the first two commands only stage changes.

Verify:

```sh
fapolicyd-cli --list | grep -c oc-mirror     # non-zero
oc version --client                          # now runs
```

> ⚠️ **STIG** Repeat this on **both** hosts, and again after replacing a
> binary — the trust entry covers a specific file, and an updated `oc-mirror`
> is a new file.

---

## fapolicyd also blocks interpreters reading scripts

**Symptom**

```
python3: can't open file '/home/user/helper.py': [Errno 1] Operation not permitted
```

The file exists, you own it, the permissions are fine. `file` cannot read it
either.

**Cause**

fapolicyd governs `open` as well as `execute`. Its RHEL policy defines a
`%languages` set -- Python, Perl, Ruby, Lua, JavaScript, shell variants and
more -- and only lets an interpreter open files of those types when they are
in the trust database. A script you just wrote is not.

Classification is by content, not file extension, so the behaviour looks
erratic until you know the rule:

| File | libmagic type | Result |
|---|---|---|
| `print(1)` | `text/plain` | runs |
| a real script with imports and functions | Python source | **EPERM** |

A trivial test script works, which is exactly how you talk yourself into
believing the problem is something else.

**Fix**

Either trust the file:

```sh
sudo fapolicyd-cli --file add /path/to/helper.py
sudo fapolicyd-cli --update
```

Or -- better -- do not put interpreted scripts on disk at all. Pipe them
through standard input, where there is no file to open:

```sh
python3 - <<EOF
import json, sys
...
EOF
```

> ⚠️ **STIG** Every script in this repository uses the stdin form for
> this reason. If you extend it, keep doing so: a `.py` helper sitting
> beside the shell scripts will not run on a hardened host, and the error
> will not point at fapolicyd.

---

## SELinux mislabels extracted binaries

**Symptom**

`Permission denied` on execution, with AVC denials in the audit log:

```sh
sudo ausearch -m AVC -ts recent
```

**Cause**

`tar` writes files with the label of the extraction context, not the label
`/usr/local/bin` expects (`bin_t`).

**Fix**

```sh
sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror
```

Do this *before* the fapolicyd step — relabelling changes the file, and
fapolicyd should trust the final version.

---

## oc-mirror requires umask 0022

**Symptom**

Every `oc-mirror` invocation opens with:

```
[WARN] : ⚠️  Detected bad umask 0077 (oc-mirror requires a umask of 0022)
```

**Cause**

STIG sets `umask 0077`. `oc-mirror` writes cache entries, archive contents
and generated manifests that must be readable by other processes and
accounts — the Quay container, and whoever applies the cluster resources
later.

**Fix**

Relax the umask for any shell that runs `oc-mirror`:

```sh
umask 0022
oc-mirror --v2 -c config.yaml file://./mirror-out
```

The scripts in this repo call `use_oc_mirror_umask` (in
`scripts/lib/common.sh`), which sets it and says so.

> ⚠️ **STIG** This applies to **every** `oc-mirror` operation — mirror-to-disk
> on the connected bastion as much as the push on the registry host. It is
> easy to notice the umask requirement while installing Quay and miss that
> the mirroring tool has the same requirement.
>
> Verified against `oc-mirror` 4.21 on RHEL 9.6: the warning is emitted at
> `0077` and absent at `0022`.

Do **not** fix this by changing the system-wide umask. Relax it per-shell or
per-script; the hardened default is there for a reason and changing it is a
finding.

---

## A restrictive umask breaks the Quay install

**Symptom**

`mirror-registry install` reports success. Quay containers then crash-loop:

```
Permission denied: '/quay-registry/conf/stack/config.yaml'
```

**Cause**

STIG sets `umask 0077` (or `0027`) in `/etc/profile` and
`/etc/login.defs`. The installer creates `${QUAY_ROOT}/quay-config` and
`${QUAY_ROOT}/quay-rootCA` with that mask, so they end up `0700`. The Quay
container runs as a different UID and cannot read them.

**Fix — two parts, both needed**

Relax the umask for the installer only:

```sh
umask 0022 && ./mirror-registry install \
  --quayHostname "${REGISTRY_HOST}" \
  --quayRoot "${QUAY_ROOT}" \
  --initUser init \
  --initPassword '<password>'
```

Then make it durable, because the installer is not the only thing that
writes those directories — upgrades and restarts recreate them:

```sh
mkdir -p ~/.config/systemd/user/quay-app.service.d
cat > ~/.config/systemd/user/quay-app.service.d/fix-perms.conf <<EOF
[Service]
ExecStartPre=/bin/bash -c 'chmod -R 755 ${QUAY_ROOT}/quay-config ${QUAY_ROOT}/quay-rootCA; chmod 644 ${QUAY_ROOT}/quay-config/* ${QUAY_ROOT}/quay-rootCA/*'
EOF
systemctl --user daemon-reload
systemctl --user restart quay-app.service
```

> ⚠️ **STIG** Order matters. Create the drop-in **after** `mirror-registry
> install`, because the unit must exist before `daemon-reload` will pick up
> a drop-in for it. Creating it first silently does nothing.

Check which umask you have:

```sh
umask                       # current shell
grep -rE '^\s*umask' /etc/profile /etc/bashrc /etc/login.defs 2>/dev/null
```

---

## User services die at logout

**Symptom**

Quay works while you are logged in and is gone the next morning. Or a
multi-hour `oc-mirror` run dies when your SSH session drops.

**Cause**

`mirror-registry` installs Quay as a **user** systemd service. Without
lingering enabled, systemd tears down the user manager at logout.

**Fix**

```sh
sudo loginctl enable-linger $USER
loginctl show-user $USER | grep Linger     # Linger=yes
```

For long mirroring runs, also detach the session:

```sh
systemd-run --scope --user tmux new -s mirror
# ... start the mirror, then detach with Ctrl-b d
# after a reconnect:
tmux attach -t mirror
```

A plain `tmux new` is not enough — without the `systemd-run --scope`
wrapper the session is still in your login scope and dies with it.

---

## oc-mirror needs port 55000

**Symptom**

```
error: unable to start local storage: listen tcp :55000: bind: permission denied
```

**Cause**

`oc-mirror` v2 runs a local container registry on port 55000 for its own
use. Hardened hosts may have firewalld rules, SELinux port labelling, or
another process in the way.

**Fix**

Check first:

```sh
ss -ltnp | grep 55000
```

Port 55000 is unprivileged, so SELinux usually permits it. If something else
holds it, change it rather than fighting for it:

```sh
oc-mirror --v2 --port 56000 ...
```

This is a loopback listener. It does **not** need a firewall rule, and you
should not add one.

---

## $HOME is the wrong place for the cache

**Symptom**

Mirroring fails hours in with `no space left on device`, while `df -h` shows
plenty free on the disk you provisioned.

**Cause**

`oc-mirror` defaults its cache to `$HOME`, storing data under
`$HOME/.oc-mirror/.cache`. STIG'd builds commonly put `/home` on a small
separate partition, often with quotas.

**Fix**

Always set it explicitly:

```sh
oc-mirror --v2 --cache-dir /data/oc-mirror-cache ...
```

Or `export OC_MIRROR_CACHE=/data/oc-mirror-cache`. The two are mutually
exclusive — setting both is an error.

The cache holds roughly the full uncompressed content set, and it is
*separate from* the archive output. Budget for both.

---

## $TMPDIR defaults to a STIG partition

**Symptom**

The push fails with `no space left on device` naming a path under
`/var/tmp`, while `CACHE_DIR`, the import directory and the podman
graphroot all have room.

**Cause**

Two different consumers, same directory:

- `oc-mirror` unpacks its v2 helper binary into the system temp directory
  and executes it from there.
- The embedded containers/image library stages temporary image content in
  `image_copy_tmp_dir`, which **defaults to `/var/tmp`** regardless of what
  `--cache-dir` is set to. Confirm with `podman info | grep imageCopyTmpDir`.

STIG is what turns this into a failure. `/var/tmp` must be a separate file
system (V-257848), and the scap-security-guide RHEL 9 kickstart gives it
**5 GB**, mounted `nodev,nosuid,noexec`. A single large layer overruns it.

> This is *not* `/var/lib/containers`. That is the rootful podman graphroot;
> `mirror-registry install` runs rootless here, so Quay's image data goes to
> the invoking user's graphroot — see [06-registry.md](06-registry.md).

**Fix**

Point `TMPDIR` at a filesystem with room, in the shell that runs
oc-mirror. It is separate from `--cache-dir`; set both:

```sh
mkdir -p /data/tmp
export TMPDIR=/data/tmp
oc-mirror --v2 --cache-dir /data/oc-mirror-cache ...
```

**Make it durable.** That `export` dies with the shell, and these are
multi-hour runs you will reconnect to after a dropped session — the one
moment you are least likely to remember re-exporting it. On a host
dedicated to this workflow, set it for every login shell:

```sh
echo 'export TMPDIR=/data/tmp' | sudo tee /etc/profile.d/oc-mirror-tmpdir.sh
sudo chmod 0644 /etc/profile.d/oc-mirror-tmpdir.sh
sudo restorecon -v /etc/profile.d/oc-mirror-tmpdir.sh
```

To keep it to one account instead, append the same line to
`~/.bash_profile`. Either way, `00-preflight.sh` prints the `TMPDIR` the
current shell would actually use and fails if it is small or `noexec`, so
a lost export surfaces before the run rather than hours into it.

> An already-running `tmux` server keeps the environment it was started
> with. After adding the drop-in, start a new session — or `tmux kill-server`
> first — or the mirror still runs with the old `TMPDIR`.

Three things that catch people:

- **The target must be exec-capable and fapolicyd-allowed.** oc-mirror runs
  a binary it unpacks there, so a `noexec` mount trades the disk error for
  `fork/exec ...: operation not permitted` — the same failure as
  [fapolicyd blocks binaries you just installed](#fapolicyd-blocks-binaries-you-just-installed).
- **`sudo` strips `TMPDIR`.** Use `sudo -E`, or set it inline.
- **Setting `image_copy_tmp_dir` in `containers.conf` is not sufficient** —
  there is a long-standing bug where `/var/tmp` is still used. `TMPDIR` is
  the knob that works.

> Using this repo's scripts? Set `MIRROR_TMPDIR` in `config/prep.env`.
> `20-mirror-to-disk.sh` and `60-push-to-registry.sh` export it as
> `TMPDIR` and probe that the target will execute, which is the first
> bullet above.

**Sources**

- <https://www.stigviewer.com/stigs/red_hat_enterprise_linux_9/2026-02-05/finding/V-257848> — RHEL 9 must use a separate file system for `/var/tmp`
- <https://access.redhat.com/solutions/6991757> — how to change `imageCopyTmpDir`
- <https://docs.podman.io/en/latest/markdown/podman.1.html> — `TMPDIR` / `image_copy_tmp_dir`, default `/var/tmp`
- <https://github.com/containers/podman/issues/14091> — `image_copy_tmp_dir` ignored without `TMPDIR`
- <https://github.com/openshift/oc-mirror/pull/1220> — oc-mirror v2 unpacks to the temp dir; `TMPDIR` is the supported override

---

## Certificate trust is system-wide, not per-command

`oc-mirror` reads TLS trust from the host trust store. There is no
`--cacert` equivalent.

```sh
sudo cp "${QUAY_ROOT}/quay-rootCA/rootCA.pem" \
        /etc/pki/ca-trust/source/anchors/quay-rootCA.pem
sudo update-ca-trust
```

Verify, and prefer this over reaching for `--insecure`:

```sh
curl -I "https://${REGISTRY_HOST}:8443/v2/"
```

> Resist `--dest-tls-verify=false`. It papers over a broken trust chain that
> the *cluster* will hit later, when it is much harder to diagnose — and in
> an accredited environment, disabled TLS verification in a build transcript
> is a finding.

---

## Credential file locations

`oc-mirror` resolves registry credentials in this order:

1. `--authfile <path>`
2. `$REGISTRY_AUTH_FILE`
3. `${XDG_RUNTIME_DIR}/containers/auth.json`
4. `~/.docker/config.json`

This repo always passes `--authfile` explicitly. Relying on the ambient
location means the command behaves differently under `sudo`, under a
different login, or in a systemd unit — all of which happen on these hosts.

```sh
chmod 600 "${RH_PULL_SECRET}" "${MIRROR_PULL_SECRET}"
```

> ⚠️ **STIG** The Red Hat pull secret is a credential. It belongs on the
> connected bastion only. Do not transfer it across the airgap — the
> disconnected side needs only the local Quay auth file, which this repo
> generates there.

---

## Quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `Operation not permitted` running a new binary | fapolicyd | `fapolicyd-cli --file add` + `--update` |
| `Detected bad umask 0077` from oc-mirror | umask 0077 | `umask 0022` in that shell |
| `can't open file ...: Operation not permitted` on a script | fapolicyd `%languages` rule | pipe via stdin, or `fapolicyd-cli --file add` |
| `fork/exec /tmp/oc-mirror-*: operation not permitted` | fapolicyd; the v1 shim unpacks to /tmp | use `scripts/13-catalog.sh` instead of `oc-mirror list --v1` |
| `no space left on device` naming `/var/tmp` | `TMPDIR` defaults to the 5 GB STIG partition | `export TMPDIR=` a roomy, exec-capable path |
| `Permission denied`, AVC in audit log | SELinux label | `restorecon -v` |
| Quay crash-loops after a clean install | umask 0077 | `umask 0022` + systemd drop-in |
| Quay gone after logout | no linger | `loginctl enable-linger` |
| Mirror dies when SSH drops | no linger / no tmux | `systemd-run --scope --user tmux` |
| `bind: permission denied` on 55000 | port in use | `--port 56000` |
| `no space left` with free disk | cache defaulted to `$HOME` | `--cache-dir` |
| `x509: certificate signed by unknown authority` | CA not trusted | `update-ca-trust` |
