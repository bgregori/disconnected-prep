# Reference material

Vendored upstream documentation and source material. Not authoritative —
kept here so the repository is useful on a disconnected bastion where none
of it can be fetched.

The vendored files are unmodified, so their internal links point at upstream
siblings that are not vendored here and will not resolve. That is expected.

## Upstream oc-mirror documentation

Retrieved 2026-10-02 from <https://github.com/openshift/oc-mirror> (`main`).

| File | Upstream path |
|---|---|
| `oc-mirror-mirroring-workflows.md` | `docs/features/mirroring-workflows.md` |
| `oc-mirror-archive-management.md` | `docs/features/archive-management.md` |
| `oc-mirror-cluster-resources.md` | `docs/features/cluster-resources.md` |
| `oc-mirror-troubleshooting.md` | `TROUBLESHOOTING.md` |

These are the basis for three corrections this repo makes to commonly
circulated airgap procedures:

1. **`--workspace` is mirror-to-mirror only.** Combining it with a `file://`
   destination is an explicit error, not a refinement. Mirror-to-disk keeps
   its state at the destination.

2. **Incremental mirroring depends on reusing the same mirror-to-disk
   destination.** The history lives at
   `<destination>/working-dir/.history/`. A new dated output directory per
   run — a widely published pattern — produces a full archive every time.

3. **`oc-mirror` deletes existing `mirror_*.tar` from the destination**
   before each run. Archives not yet transferred are lost.

Also confirmed from source (`internal/pkg/cli/executor.go`,
`internal/pkg/mirror/options.go`):

- `--authfile` is a real, supported flag, defaulting to `$REGISTRY_AUTH_FILE`
  then `${XDG_RUNTIME_DIR}/containers/auth.json`.
- `oc-mirror` runs a local storage instance on port **55000** (`--port`).
- `--max-nested-paths` exists for registries that limit repository depth.
- `--cache-dir` defaults to `$HOME`; data lands at `<dir>/.oc-mirror/.cache`.

Behaviour was read from `main`, which may run ahead of the `oc-mirror`
build shipped with a given OpenShift release. Where a detail is
version-sensitive it is flagged inline in `docs/`. Verify against your own
binary when in doubt:

```sh
oc-mirror --v2 --help
```

## Source material

`original-sno-guide.md` — the OpenShift Virtualization 4.21 airgapped SNO
deployment guide this repository was derived from.

Retained for provenance and because its later chapters cover the
**install-side** work that is deliberately out of scope here: SNO
topology, LVMS configuration, HyperConverged deployment, DataVolume boot
sources, Compliance Operator and File Integrity Operator setup.

It is **not** maintained and contains errors corrected in `docs/` —
including the three `oc-mirror` issues above, a `--workspace` flag used
with a `file://` destination, inconsistent `QUAY_ROOT` paths, and a
relative `--idms-file` path. Treat it as history, not as instructions.
