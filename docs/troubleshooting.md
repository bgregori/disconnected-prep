# Troubleshooting

Organised by the error you are seeing. For hardening-specific failures, see
[appendix-fips-stig.md](appendix-fips-stig.md) — most "this should obviously
work" problems on these hosts are there.

---

## First moves

```sh
# ===== RUN ON: BOTH HOSTS =====
# verbose
oc-mirror --v2 --log-level=debug ...

# logs
ls -lt <workspace>/working-dir/logs/
tail -f <workspace>/working-dir/logs/oc-mirror-*.log

# what would happen, without doing it
oc-mirror --v2 -c config.yaml --dry-run file://./mirror-out
```

---

## Binaries and the host

### `Operation not permitted` running `oc` or `oc-mirror`

fapolicyd. Permissions and ownership look fine; execution is denied anyway.

```sh
# ===== RUN ON: BOTH HOSTS =====
sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror
sudo fapolicyd-cli --file add /usr/local/bin/oc
sudo fapolicyd-cli --file add /usr/local/bin/oc-mirror
sudo fapolicyd-cli --update
```

Relabel first: it changes the file, so trusting it beforehand achieves
nothing. The trust database is per-host — doing this on one host does not
cover the other. Background in
[appendix-fips-stig.md](appendix-fips-stig.md#fapolicyd-blocks-binaries-you-just-installed).

### `Permission denied`, AVC denials in the audit log

SELinux label from `tar` extraction.

```sh
# ===== RUN ON: BOTH HOSTS =====
sudo ausearch -m AVC -ts recent
sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror
```

### `error: unable to start local storage: listen tcp :55000`

`oc-mirror` runs a local registry on 55000.

```sh
# ===== RUN ON: BOTH HOSTS =====
ss -ltnp | grep 55000
oc-mirror --v2 --port 56000 ...
```

Loopback only — it does not need a firewall rule.

---

## Configuration

### `use the mandatory --config flag`

`-c`/`--config` is required for **every** mirroring operation, including
disk-to-mirror. Omitting it on the push side is a frequent mistake.

### `when destination is docker://, either --from or --workspace need to be provided`

The workflow is chosen by argument shape:

| Destination | `--from` | `--workspace` | Workflow |
|---|---|---|---|
| `file://` | — | — | mirror-to-disk |
| `docker://` | `file://` | — | disk-to-mirror |
| `docker://` | — | `file://` | mirror-to-mirror |

Pushing an archive to a registry is disk-to-mirror: use `--from`.

### Error when passing both `--workspace` and a `file://` destination

Invalid combination. `--workspace` is mirror-to-mirror only. For
mirror-to-disk, state lives at the `file://` destination and no workspace
flag exists.

### `Ignoring unrecognized environment variable REGISTRY_...`

oc-mirror embeds docker/distribution for its local storage instance, and
that reads configuration from the whole `REGISTRY_*` environment namespace.
Any exported variable starting with `REGISTRY_` is examined by it.

Harmless when the name is unrecognised — but a name it *does* recognise
(`REGISTRY_STORAGE_*`, `REGISTRY_HTTP_*`, `REGISTRY_LOG_*`) will silently
reconfigure oc-mirror's internal registry.

Do not export `REGISTRY_`-prefixed variables in a shell that runs
oc-mirror. `scripts/lib/common.sh` sources `prep.env` without `set -a` for
this reason, keeping the values shell-local.

Note `REGISTRY_AUTH_FILE` is a genuine, intentional exception: oc-mirror
reads it as the default `--authfile` path.

### Package not found / operator silently absent

Verify against the real catalog rather than assuming:

```sh
# ===== RUN ON: CONNECTED BASTION =====
oc-mirror list operators \
  --catalog=registry.redhat.io/redhat/redhat-operator-index:v4.21 \
  --package=<name> --v2
```

Channel naming is inconsistent: `stable`, `stable-4.21`, `stable-1.4`,
`latest` all occur. Check per operator.

---

## Disk and cache

### `no space left on device`, but `df` shows free space

The cache defaulted to `$HOME`, which on a STIG'd build is often a small
separate partition.

```sh
# ===== RUN ON: BOTH HOSTS =====
oc-mirror --v2 --cache-dir /data/oc-mirror-cache ...
```

Remember the cache and the archive output are two full-size copies.

### Archives larger than expected

A version *range* mirrors every release between min and max. For a single
version, set `minVersion == maxVersion`.

### Archive too large for the transport medium

```yaml
archiveSize: 50      # GB per segment
```

Add `--strict-archive` to fail rather than exceed the limit when a single
file is too large.

### Previous archives disappeared

Expected: `oc-mirror` deletes `mirror_*.tar` from the destination before
each run. This repo stages copies into `exports/<tag>/` for that reason.

---

## Registry and TLS

### `x509: certificate signed by unknown authority`

The CA is not in the host trust store. `oc-mirror` has no per-command
certificate flag.

```sh
# ===== RUN ON: REGISTRY HOST =====
sudo cp /opt/quay/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
curl -I https://registry.airgap.local:8443/v2/      # must work without -k
```

Avoid `--dest-tls-verify=false`; it defers the problem to the cluster.

### `unauthorized: access to the requested resource is not authorized`

The auth file key must match the `docker://` target **exactly**, including
the port.

```sh
# ===== RUN ON: REGISTRY HOST =====
python3 -m json.tool < mirror-pull-secret.json
podman login --authfile mirror-pull-secret.json registry.airgap.local:8443
```

`registry.airgap.local` and `registry.airgap.local:8443` are different keys.

### Destination parsed as a repository, not a registry

An unqualified hostname is treated as an image name. Use an FQDN or an IP.
`localhost` is a special case that works.

### Registry rejects deeply nested paths

Common with Artifactory and Harbor.

```sh
# ===== RUN ON: REGISTRY HOST =====
oc-mirror --v2 --max-nested-paths 2 ...
```

See [appendix-byo-registry.md](appendix-byo-registry.md).

---

## Quay

### Quay crash-loops after a successful install

STIG umask. `quay-config` was created `0700` and the container cannot read
it.

```sh
# ===== RUN ON: REGISTRY HOST =====
ls -ld /opt/quay/quay-config
podman logs quay-app | tail -40
```

Fix: `umask 0022` for the install, plus the systemd drop-in in
[05-registry.md](05-registry.md).

### Quay disappears after logout

```sh
# ===== RUN ON: REGISTRY HOST =====
sudo loginctl enable-linger $USER
```

### The systemd drop-in appears to do nothing

It was created before `mirror-registry install` created the unit, or its
paths do not match the real `QUAY_ROOT`.

```sh
# ===== RUN ON: REGISTRY HOST =====
systemctl --user cat quay-app.service | grep -A3 ExecStartPre
```

---

## Release extraction

### `oc adm release extract` cannot reach the upstream registry

Usually a bad `--idms-file` path — `oc` resolves it relative to the current
directory, and a wrong relative path means no mirror rewriting happens, so
it tries the real `quay.io`.

Use an absolute path.

### Extracted installer reports the wrong version

Check the tag you extracted from, and that `--command=openshift-install-fips`
was used rather than `openshift-install`. A `fips: true` cluster requires
the FIPS binary.

---

## Long runs

### Mirroring dies when the SSH session drops

```sh
# ===== RUN ON: BOTH HOSTS =====
sudo loginctl enable-linger $USER
systemd-run --scope --user tmux new -s mirror
```

A plain `tmux new` is still in your login scope.

### Upstream throttling

```sh
# ===== RUN ON: CONNECTED BASTION =====
oc-mirror --v2 --parallel-images 2 --parallel-layers 2 ...
```

### Resuming an interrupted run

Re-run the same command. The cache is reused and completed work is skipped.
No cleanup needed.

---

## Still stuck

1. `--log-level=trace`, and read `working-dir/logs/`.
2. Reproduce with `--dry-run` — separates "cannot resolve" from "cannot
   transfer".
3. Shrink the ImageSetConfiguration to one operator and retry. Isolating
   which entry fails is usually faster than reading a long log.
4. Check [appendix-fips-stig.md](appendix-fips-stig.md) once more — on a
   hardened host it is usually the host.

Upstream references, mirrored into `reference/` for offline use:
<https://github.com/openshift/oc-mirror>
