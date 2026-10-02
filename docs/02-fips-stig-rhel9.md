# FIPS and STIG on the RHEL 9 bastions

Everything in this chapter exists because the bastion is hardened. On a
stock RHEL 9 box none of it is necessary, which is why none of it appears in
the standard Red Hat mirroring documentation.

Each failure below is one that produces a misleading error. If you are
debugging something that "should obviously work", start here.

---

## First, a distinction

Two separate things get conflated constantly:

**Bastion FIPS mode** — whether the bastion host itself boots with
`fips=1`. It affects which crypto the mirroring tools may use. It is *not*
required for mirroring, and not required to produce a FIPS cluster.

**Cluster FIPS mode** — `fips: true` in `install-config.yaml`. This is what
the accreditation actually cares about. It is set at install time and cannot
be changed afterwards.

You can mirror from a non-FIPS bastion to build a FIPS cluster. The one
genuine coupling is the installer binary: a cluster with `fips: true`
requires `openshift-install-fips`, extracted from the release payload. See
[08-verify.md](08-verify.md).

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

> ⚠️ **STIG** Repeat this on **both** bastions, and again after replacing a
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
> on the connected bastion as much as the push on the disconnected one. It is
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
| `Permission denied`, AVC in audit log | SELinux label | `restorecon -v` |
| Quay crash-loops after a clean install | umask 0077 | `umask 0022` + systemd drop-in |
| Quay gone after logout | no linger | `loginctl enable-linger` |
| Mirror dies when SSH drops | no linger / no tmux | `systemd-run --scope --user tmux` |
| `bind: permission denied` on 55000 | port in use | `--port 56000` |
| `no space left` with free disk | cache defaulted to `$HOME` | `--cache-dir` |
| `x509: certificate signed by unknown authority` | CA not trusted | `update-ca-trust` |
