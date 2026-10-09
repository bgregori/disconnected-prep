# Mirror to disk

On the **connected** bastion. Pulls everything in the ImageSetConfiguration
into tar archives.

```sh
# ===== RUN ON: CONNECTED BASTION =====
ROLE=connected ./scripts/00-preflight.sh
./scripts/20-mirror-to-disk.sh
```

By now the tooling and pull secret are in place from
[01-prerequisites.md](01-prerequisites.md#install-the-tooling), and
`imageset-config.yaml` exists from
[02-plan-your-content.md](02-plan-your-content.md). So this is the
preflight run that must **exit clean** — the last gate before a multi-hour
download.

Missing `oc` or `oc-mirror` means chapter 1's tooling step was skipped; a
missing ImageSetConfiguration means chapter 2 was.

---

## Tooling

Installed in
[01-prerequisites.md](01-prerequisites.md#install-the-tooling), along with
the pull secret at `${OCP_AIRGAP_ROOT}/binaries/pull-secret.json`.
Confirm before starting a long run:

```sh
# ===== RUN ON: CONNECTED BASTION =====
: "${OCP_AIRGAP_ROOT:?set it first -- see 01-prerequisites.md}"
oc version --client
( umask 0022; oc-mirror version --v2 >/dev/null && echo "oc-mirror OK" )
ls ${OCP_AIRGAP_ROOT}/config/imageset-config.yaml
```

---

## Survive a dropped session

A full mirror runs for hours. An SSH disconnect kills it and you start over.

```sh
# ===== RUN ON: CONNECTED BASTION =====
sudo loginctl enable-linger $USER
systemd-run --scope --user tmux new -s mirror
```

Detach with `Ctrl-b d`, reattach with `tmux attach -t mirror`.

The `systemd-run --scope` wrapper matters: a bare `tmux new` still belongs
to your login session scope and dies with it.

---

## Run the mirror

```sh
# ===== RUN ON: CONNECTED BASTION =====
cd ${OCP_AIRGAP_ROOT}

umask 0022
export TMPDIR=/data/tmp
oc-mirror --v2 \
  --config config/imageset-config.yaml \
  --cache-dir ./cache \
  --authfile binaries/pull-secret.json \
  file://./mirror-out
```

> ⚠️ **STIG** The `umask 0022` is required, not cosmetic. At the STIG default
> of `0077`, `oc-mirror` warns `Detected bad umask 0077 (oc-mirror requires a
> umask of 0022)` and writes cache and archive content other accounts cannot
> read. This applies to the connected side too, not only the registry push.

> ⚠️ **STIG** `TMPDIR` is load-bearing for the same reason the `umask` is —
> both are per-shell settings this run depends on. Unset, oc-mirror stages
> blobs in `/var/tmp`, which STIG gives its own 5 GB filesystem, and the run
> dies partway through on `no space left on device`. The target needs room
> and must permit execution. Set it durably rather than retyping it after
> every reconnect —
> [01-prerequisites.md](01-prerequisites.md#where-the-prep-tree-lives) has the
> drop-in, and
> [the appendix](appendix-fips-stig.md#tmpdir-defaults-to-a-stig-partition)
> has the why.

This is **mirror-to-disk (m2d)**. The workflow is selected by argument
shape, not by a flag:

| Destination | `--from` | `--workspace` | Workflow |
|---|---|---|---|
| `file://` | — | — | **mirror-to-disk** |
| `docker://` | `file://` | — | disk-to-mirror |
| `docker://` | — | `file://` | mirror-to-mirror |

> **`--workspace` is for mirror-to-mirror only.** Combining it with a
> `file://` destination is an error, not a refinement. If you have seen a
> guide that passes both, it is wrong — and it will have been masking the
> fact that m2d keeps its state at the destination instead.

---

## Use the same output directory every time

This is the part guides most often get backwards.

`oc-mirror` tracks what it has already mirrored in a history file under
`<destination>/working-dir/.history/`. On a second run against the **same**
destination it emits only new blobs — that is what makes Day-2 updates
cheap.

Point it at a fresh dated directory each run and there is no history, so
every run produces a **full** archive.

> A dry run creates the workspace, including an empty `.history/`, without
> recording anything in it. The first real mirror afterwards is still a full
> archive — judge by the files inside `.history/`, not by the directory
> existing.

So: one persistent `MIRROR_OUT`, and dated copies staged out of it for
transport.

```
${OCP_AIRGAP_ROOT}/                 e.g. /data/ocp-airgap
├── cache/                    PERSISTENT  layer cache (--cache-dir)
├── mirror-out/               PERSISTENT  m2d destination; history lives here
│   ├── mirror_000001.tar                 current run's archives
│   └── working-dir/
│       ├── .history/                     ← the thing that enables deltas
│       └── logs/
└── exports/                              dated copies for transport
    ├── 2026-10-02_initial/
    └── 2026-12-01_day2/
```

> ⚠️ **`oc-mirror` deletes existing `mirror_*.tar` from the destination
> before each run.** That is why `20-mirror-to-disk.sh` copies archives out
> to `exports/<tag>/` immediately afterwards. If you need an archive, copy
> it before re-running.

---

## While it runs

Logs stream to the terminal and to
`mirror-out/working-dir/logs/oc-mirror-<timestamp>.log`.

```sh
# ===== RUN ON: CONNECTED BASTION =====
du -sh ${OCP_AIRGAP_ROOT}/cache ${OCP_AIRGAP_ROOT}/mirror-out
tail -f ${OCP_AIRGAP_ROOT}/mirror-out/working-dir/logs/oc-mirror-*.log
```

If the upstream registry throttles, reduce parallelism:

```sh
--parallel-images 2 --parallel-layers 2
```

An interrupted run is resumable — re-run the same command and the cache is
reused. You do not need to start clean.

---

## Stage for transfer

Everything here is under `${OCP_AIRGAP_ROOT}`, including `exports/` —
the destination is `${OCP_AIRGAP_ROOT}/exports/<tag>/`, not `~/exports/`.
The mirror is hours old by now and you are probably in a fresh shell, so the `cd` is
part of the block:

```sh
# ===== RUN ON: CONNECTED BASTION =====
cd ${OCP_AIRGAP_ROOT}

mkdir -p exports/2026-10-02_initial
cp mirror-out/mirror_*.tar exports/2026-10-02_initial/
cp config/imageset-config.yaml exports/2026-10-02_initial/
```

Carrying the ImageSetConfiguration alongside the archives matters: the
disk-to-mirror step requires `--config`, and it is also your only record of
what this bundle contains.

> Using the scripts? `20-mirror-to-disk.sh` has already done this, to
> `${EXPORTS_DIR}/${EXPORT_TAG}` from `config/prep.env` — by default
> `${OCP_AIRGAP_ROOT}/exports/2026-10-02_initial/`. Check before copying again:
> `ls -lh ${OCP_AIRGAP_ROOT}/exports/*/`.

---

Next: [04-transfer.md](04-transfer.md)
