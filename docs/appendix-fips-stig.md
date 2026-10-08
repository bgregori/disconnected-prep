# Appendix — FIPS and STIG on the RHEL 9 hosts

**This is reference, not a step. Nothing here needs to be run on its own.**

Everything in this appendix exists because these hosts are hardened. On a
stock RHEL 9 box none of it is necessary, which is why none of it appears in
the standard Red Hat mirroring documentation.

Each fix is already applied at the point in the chapters where it is needed
— the fapolicyd allowlist while installing the tooling, `umask 0022` on
every `oc-mirror` invocation, the Quay permissions during the install. Work
through the chapters in order and you will have done all of it without
reading this.

What is here is the *why*: each entry is a hardening control, the
misleading error it produces, and where in the chapters it is handled. If
you are debugging something that "should obviously work", start here. Some
blocks below are illustrative fragments rather than commands to paste —
they show the shape of the fix, and the chapter named in each entry has the
real one.

Host FIPS mode versus cluster FIPS mode — which hosts need `fips=1`, and
which do not — is a provisioning decision rather than a failure mode, so it
lives in
[01-prerequisites.md](01-prerequisites.md#fips-mode-host-versus-cluster).

[docs/troubleshooting.md](troubleshooting.md) indexes the same failures by
symptom, in short form. Use that when you have an error message in front of
you and this when the short form was not enough.

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
# ===== RUN ON: BOTH HOSTS =====
sudo fapolicyd-cli --file add /usr/local/bin/oc
sudo fapolicyd-cli --file add /usr/local/bin/oc-mirror
sudo fapolicyd-cli --update
```

`--update` is required; the first two commands only stage changes.

Installing the tooling already runs this — on the connected bastion in
[01-prerequisites.md](01-prerequisites.md#install-the-tooling), and again
on the registry host in [05-registry.md](05-registry.md), because the
trust database is per-host. You are here because it did not take, or
because you have added a binary since. Pair it with
[SELinux mislabels extracted binaries](#selinux-mislabels-extracted-binaries):
both bite the same freshly extracted file, and relabelling after
allowlisting undoes the trust.

Verify:

```sh
# ===== RUN ON: BOTH HOSTS =====
fapolicyd-cli --list | grep -c oc-mirror     # non-zero
oc version --client                          # now runs
```

> ⚠️ **STIG** Repeat this on **both** hosts, and again after replacing a
> binary — the trust entry covers a specific file, and an updated `oc-mirror`
> is a new file.

---

## fapolicyd also blocks interpreters reading scripts

*Nothing in the chapters needs this — it is the rule to follow if you add
tooling of your own.*

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
# ===== RUN ON: BOTH HOSTS =====
sudo fapolicyd-cli --file add /path/to/helper.py
sudo fapolicyd-cli --update
```

Or -- better -- do not put interpreted scripts on disk at all. Pipe them
through standard input, where there is no file to open:

```sh
# ===== RUN ON: BOTH HOSTS =====
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

*Already done when the tooling is installed:
[01-prerequisites.md](01-prerequisites.md#install-the-tooling) on the
connected bastion, [05-registry.md](05-registry.md) on the registry host.*

**Symptom**

`Permission denied` on execution, with AVC denials in the audit log:

```sh
# ===== RUN ON: BOTH HOSTS =====
sudo ausearch -m AVC -ts recent
```

**Cause**

`tar` writes files with the label of the extraction context, not the label
`/usr/local/bin` expects (`bin_t`).

**Fix**

```sh
# ===== RUN ON: BOTH HOSTS =====
sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror
```

Do this *before* the fapolicyd step — relabelling changes the file, and
fapolicyd should trust the final version.

---

## oc-mirror requires umask 0022

*Already on every `oc-mirror` invocation in the chapters —
[02](02-plan-your-content.md), [03](03-connected-mirror.md),
[06](06-push-to-registry.md), [09](09-day2-delta.md).*

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
# ===== RUN ON: BOTH HOSTS =====
umask 0022
oc-mirror --v2 -c config.yaml file://./mirror-out
```

The scripts in this repo call `use_oc_mirror_umask` (in
`scripts/lib/common.sh`), which sets it and says so.

> ⚠️ **STIG** This applies to **every** `oc-mirror` operation — mirror-to-disk
> on the connected bastion as much as the push on the registry host.
>
> Verified against `oc-mirror` 4.21 on RHEL 9.6: the warning is emitted at
> `0077` and absent at `0022`.
>
> Unlike the Quay install, this one *is* fixed by setting the umask in
> your own shell, because `oc-mirror` runs in it. The Quay installer does
> not — see [Quay cannot read its own
> config](#quay-cannot-read-its-own-config) — and conflating the two is
> how people conclude the umask advice is cargo cult.

Do **not** fix this by changing the system-wide umask. Relax it per-shell or
per-script; the hardened default is there for a reason and changing it is a
finding.

---

## Quay cannot read its own config

*Handled during the install in [05-registry.md](05-registry.md), which
carries the ACL, the umask window and the drop-in.*

**Symptom**

`mirror-registry install` fails after ten polls of `/health/instance`:

```
Status code was -1 and not [200]: Request failed:
<urlopen error TLS/SSL connection has been closed (EOF)>
```

or, if it got that far, Quay containers crash-loop with

```
open /quay-registry/conf/stack/config.yaml: permission denied
```

The TLS wording is a red herring. Rootless podman publishes the port
through a userspace proxy that accepts the connection and closes it when
nothing is listening behind, so a crash-looping `quay-app` presents as a
TLS fault.

**Cause**

Quay reads its configuration as a non-root UID *inside* the container,
which rootless podman maps to a high subuid on the host — container
`1001` with base `100000` is host `101000`. The installer writes
`config.yaml` over its own SSH session to localhost, under the umask PAM
gives that session: `0077` on a STIG build. A `0600` file owned by your
account is unreadable to the mapped UID.

Note what this is not. `EACCES` ("Permission denied") is ordinary file
permission; fapolicyd denials are `EPERM` ("Operation not permitted") —
see [fapolicyd blocks binaries you just
installed](#fapolicyd-blocks-binaries-you-just-installed). Stopping
fapolicyd for the install, as some guides suggest, does nothing here.

**Fix**

Grant the mapped UID by name and keep the directory closed to everyone
else:

```sh
# ===== RUN ON: REGISTRY HOST =====
install -d -m 0750 "${QUAY_ROOT}/quay-config" "${QUAY_ROOT}/quay-rootCA"
setfacl -R -m u:101000:rX "${QUAY_ROOT}/quay-config" "${QUAY_ROOT}/quay-rootCA"
```

Two things that look like fixes and are not:

- **`umask 0022` before the install command.** It applies to your shell;
  the files are written by the installer's SSH session, which never sees
  it. Check with `ssh -i ~/.ssh/quay_installer "$(id -un)@localhost"
  'umask'`.
- **A default ACL on a pre-created directory.** Ansible writes a temp file
  and renames it into place; default ACLs apply at creation, not at
  rename. The directory keeps the ACL, the file arrives `0600` regardless.

[05-registry.md](05-registry.md) resolves this by relaxing the umask of
the installer's own session for the length of the install — a
[V-258044](https://www.stigviewer.com/stigs/red_hat_enterprise_linux_9/2026-05-20/finding/V-258044)
deviation to time-box and revert — with the post-install repair documented
as the no-deviation alternative.

---

## User services die at logout

*Lingering is already enabled immediately before the Quay install in
[05-registry.md](05-registry.md) — the install itself needs it, not just
the logout afterwards.*

**Symptom**

Quay works while you are logged in and is gone the next morning. Or a
multi-hour `oc-mirror` run dies when your SSH session drops.

**Cause**

`mirror-registry` installs Quay as a **user** systemd service. Without
lingering enabled, systemd tears down the user manager at logout.

**Fix**

```sh
# ===== RUN ON: REGISTRY HOST =====
sudo loginctl enable-linger $USER
loginctl show-user $USER | grep Linger     # Linger=yes
```

For long mirroring runs, also detach the session:

```sh
# ===== RUN ON: BOTH HOSTS =====
systemd-run --scope --user tmux new -s mirror
# ... start the mirror, then detach with Ctrl-b d
# after a reconnect:
tmux attach -t mirror
```

A plain `tmux new` is not enough — without the `systemd-run --scope`
wrapper the session is still in your login scope and dies with it.

---

## oc-mirror needs port 55000

*Preflight in [01-prerequisites.md](01-prerequisites.md) already reports
whether the port is free.*

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
# ===== RUN ON: BOTH HOSTS =====
ss -ltnp | grep 55000
```

Port 55000 is unprivileged, so SELinux usually permits it. If something else
holds it, change it rather than fighting for it:

```sh
# ===== RUN ON: BOTH HOSTS =====
oc-mirror --v2 --port 56000 ...
```

This is a loopback listener. It does **not** need a firewall rule, and you
should not add one.

---

## $HOME is the wrong place for the cache

*Every `oc-mirror` command in the chapters already passes `--cache-dir`.*

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
# ===== RUN ON: BOTH HOSTS =====
oc-mirror --v2 --cache-dir /data/oc-mirror-cache ...
```

Or `export OC_MIRROR_CACHE=/data/oc-mirror-cache`. The two are mutually
exclusive — setting both is an error.

The cache holds roughly the full uncompressed content set, and it is
*separate from* the archive output. Budget for both.

---

## $TMPDIR defaults to a STIG partition

*Set when the hosts are provisioned, in
[01-prerequisites.md](01-prerequisites.md#where-the-prep-tree-lives).*

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
> the invoking user's graphroot — see [05-registry.md](05-registry.md).

**Fix**

Point `TMPDIR` at a filesystem with room, in the shell that runs
oc-mirror. It is separate from `--cache-dir`; set both:

```sh
# ===== RUN ON: BOTH HOSTS =====
mkdir -p /data/tmp
export TMPDIR=/data/tmp
oc-mirror --v2 --cache-dir /data/oc-mirror-cache ...
```

**Make it durable.** That `export` dies with the shell, so
[01-prerequisites.md](01-prerequisites.md#where-the-prep-tree-lives) sets it for
every login shell with a `/etc/profile.d` drop-in. `00-preflight.sh` prints
the `TMPDIR` the current shell would actually use and fails if it is small
or `noexec`, so a lost export surfaces before the run rather than hours
into it.

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

*Already done after the Quay install in [05-registry.md](05-registry.md).*

`oc-mirror` reads TLS trust from the host trust store. There is no
`--cacert` equivalent.

```sh
# ===== RUN ON: REGISTRY HOST =====
sudo cp "${QUAY_ROOT}/quay-rootCA/rootCA.pem" \
        /etc/pki/ca-trust/source/anchors/quay-rootCA.pem
sudo update-ca-trust
```

Verify, and prefer this over reaching for `--insecure`:

```sh
# ===== RUN ON: REGISTRY HOST =====
curl -I "https://${REGISTRY_HOST}:8443/v2/"
```

> Resist `--dest-tls-verify=false`. It papers over a broken trust chain that
> the *cluster* will hit later, when it is much harder to diagnose — and in
> an accredited environment, disabled TLS verification in a build transcript
> is a finding.

---

## Credential file locations

*Both pull secrets are placed and mode-restricted in
[01-prerequisites.md](01-prerequisites.md#place-the-pull-secret) and
[05-registry.md](05-registry.md).*

`oc-mirror` resolves registry credentials in this order:

1. `--authfile <path>`
2. `$REGISTRY_AUTH_FILE`
3. `${XDG_RUNTIME_DIR}/containers/auth.json`
4. `~/.docker/config.json`

This repo always passes `--authfile` explicitly. Relying on the ambient
location means the command behaves differently under `sudo`, under a
different login, or in a systemd unit — all of which happen on these hosts.

```sh
# ===== RUN ON: BOTH HOSTS =====
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
| Quay crash-loops, or install fails on a TLS EOF | `config.yaml` `0600`; Quay reads it as a mapped subuid | `setfacl -m u:101000:rX` + systemd drop-in |
| Quay gone after logout | no linger | `loginctl enable-linger` |
| Mirror dies when SSH drops | no linger / no tmux | `systemd-run --scope --user tmux` |
| `bind: permission denied` on 55000 | port in use | `--port 56000` |
| `no space left` with free disk | cache defaulted to `$HOME` | `--cache-dir` |
| `x509: certificate signed by unknown authority` | CA not trusted | `update-ca-trust` |
