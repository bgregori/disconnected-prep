# Validation record

What in this repository has actually been executed against real
infrastructure, and what has not. Kept so that anyone handed this repo can
tell proven behaviour from reasoned behaviour.

## Environment

End-to-end run on 2026-10-02 against a purpose-built disconnected AWS
sandbox:

| | Connected bastion | Disconnected registry host |
|---|---|---|
| OS | RHEL 9.6 (Plow) | RHEL 9.6 (Plow) |
| FIPS 140-3 | enabled (`fips_enabled=1`) | enabled |
| DISA STIG | applied | applied |
| `umask` | `0077` | `0077` |
| SELinux | Enforcing | Enforcing |
| `fapolicyd` | **active** | inactive |
| `firewalld` | active | active |
| Size | 4 vCPU / 15 GB / 499 GB | 2 vCPU / 7 GB / 200 GB + 500 GB |
| Network | internet via IGW | **no route to internet** |

The private subnet had no NAT gateway, no internet gateway route and no VPC
endpoints — a genuine airgap, not a simulated one. Transfer between the two
went over the internal subnet, standing in for removable media.

Content mirrored: OpenShift **4.21.34** platform + `compliance-operator` +
`file-integrity-operator` + 3 diagnostic images = **202 images**, then a
second pass adding the GitOps operator.

## Verified

| Step | Result |
|---|---|
| `10-fetch-binaries.sh` | oc + oc-mirror installed, SELinux relabelled, fapolicyd allowlisted; both execute afterwards |
| `00-preflight.sh` | Correctly identified FIPS, umask, SELinux, fapolicyd, disk, reachability, and the two genuine blockers |
| `12-compose-imageset.sh` | Valid YAML; version variables substituted; multi-profile operator merge correct |
| `13-catalog.sh` | Catalog FBC extracted (150 packages); all 8 profile packages/channels validated |
| `15-dry-run.sh` | Resolved 202 images; produced `mapping.txt` and `missing.txt` |
| `20-mirror-to-disk.sh` | 202/202 mirrored; 29 GB archive; staged to dated export |
| `30-package-transfer.sh` | Bundle assembled; SHA256 manifest over all 7 files incl. the 29 GB archive |
| Transfer | 29 GB moved across the airgap |
| `50-install-registry.sh` | Quay installed under `umask 0077`; **config dirs came out 755/644**, i.e. the umask workaround is load-bearing and works |
| `60-push-to-registry.sh` | Checksum gate passed; 191/191 release + 8/8 operator images pushed; all cluster resources generated |
| `70-extract-installer.sh` | **`openshift-install-fips` 4.21.34 extracted from the local registry** |
| `80-verify-mirror.sh` | **7 / 7 checks passed** |
| `90-handoff.sh` | Bundle assembled, `imageDigestSources` generated from the real IDMS, checksums verify |
| CA trust | `curl` without `-k` returns 401 — TLS chain accepted from the system trust store |
| systemd drop-in | Present and active in `systemctl --user cat quay-app.service` |
| Non-interactive login | `podman login --password-stdin` succeeds |

The strongest single result is the installer extraction, because it
exercises registry auth, TLS trust, IDMS resolution and release-payload
completeness in one command. The extracted binary reported 4.21.34 with a
release image reference resolving to the **local** registry, not quay.io.

### Incremental mirroring — measured

The central correction this repo makes to commonly circulated guides.
Two UBI images, same cache throughout:

| Run | Destination | Cache | Archive |
|---|---|---|---|
| 1 | `mirror-out` — no history | cold | **186 M** |
| 2 | `mirror-out` — history present | warm | **649 K** |
| 3 | fresh directory | **warm** | **186 M** |

Run 3 isolates the mechanism: a warm cache makes a re-mirror *fast*, but
only the history at `<destination>/working-dir/.history/` makes the archive
*small*. A new dated output directory per run — a widely published
pattern — silently defeats incremental mirroring.

### Day-2 delta cycle, end to end

Full second pass: added the GitOps operator to the already-mirrored
baseline and ran config → mirror → package → transfer → push → verify.

| Step | Result |
|---|---|
| `13-catalog.sh --check` | 3 packages validated before mirroring |
| `20-mirror-to-disk.sh` | reported **DIFFERENTIAL**; archive **9.1 GB vs 29 GB** full |
| `30-package-transfer.sh` | archives only, no redundant tooling |
| Transfer | 9.1 GB across the airgap |
| `60-push-to-registry.sh` | 216 images; one transient failure, retry succeeded |
| `80-verify-mirror.sh` | 7 / 7 |
| Content check | gitops images pullable **from the mirror by digest** |

Confirms the whole of `docs/10-day2-delta.md`, not just the archive-size
mechanism.

### Size estimation — measured, then removed

A size estimator was built, tested and subsequently **removed from the
repository** in favour of flat "provision 500 GB on the registry host"
guidance. The measurements it produced are retained here because
`docs/11-capacity-planning.md` rests on them.

Two findings worth keeping:

**Sampling does not work for container image sizes.** The first version
sampled N images and extrapolated. Against the same 202-image set:

| Sample | Estimates across runs |
|---|---|
| 15 | 21, 25, 29 GiB |
| 40 | 32, 40, 52 GiB |

A 2.5× swing on identical input, and the 95% interval at `SAMPLE=15`
(18–23 GiB) excluded the real archive size. Image sizes are heavily skewed,
so whether a few large images land in the sample dominates the result. Any
future attempt at estimation should read every manifest, not sample.

**Deduplication by layer digest matters.** Reading all 202 manifests and
deduplicating gave **22.4 GiB** across 347 unique layers, against 36 GiB
counted per-image — a 37% shared-layer saving. Measured actuals for that
run:

| Location | Measured |
|---|---|
| connected cache | 25.4 GiB |
| archive | 28.5 GiB |
| export dir (archive + binaries) | 29.3 GiB |
| import dir (archive + d2m working-dir) | **32.6 GiB** |
| disconnected extraction cache | 25.2 GiB |
| registry storage (podman graphroot) | 27.0 GiB |
| **connected host total** | **53.9 GiB** |
| **registry host total** | **84.8 GiB** |

The registry host consumed ~3.8× the deduplicated download, because
imports, extraction cache and registry coexist. The import directory was
the single largest consumer — disk-to-mirror writes its `working-dir/` at
the `--from` path alongside the archive.

All of which sits comfortably inside a 500 GB registry host, which is why
the flat recommendation holds.

### Marginal growth costs (for capacity planning)

Deduplicated, measured on the same environment:

| Content | Total | Marginal |
|---|---|---|
| OCP 4.21.34 platform, amd64 | 21.3 GiB | — |
| + a second z-stream (4.21.33) | 39.9 GiB | **+18.6 GiB** |
| + virtualization (CNV) operator | 25.9 GiB | **+4.6 GiB** |
| + compliance + file-integrity + 3 diagnostic images | 22.4 GiB | **+1.1 GiB** |

Consecutive z-streams reused only 33% of layers and 13% of bytes — release
payload images are rebuilt wholesale between z-streams, so each retained
version costs close to a full payload. This is the basis for
`docs/11-capacity-planning.md`.

### Timings (small hosts; treat as upper bounds)

| Operation | Time |
|---|---|
| Mirror 202 images to disk | 14m53s (≈7m pull, ≈8m tarball) |
| Delta mirror (one operator added) | 6m16s |
| Push 202 images to Quay | 27m10s |
| SHA256 over 29 GB | several minutes on 2 vCPU, and it happens twice |
| Quay healthy after installer exits | ~80 s (502 → 503 → 200) |
| Catalog FBC extraction | ~2 min, cached thereafter |

## Bugs this testing found and fixed

Twenty-one. Every one passed local syntax and logic review and still failed
on real hardware. Listed worst-first.

### Would have broken an install

1. **`imageDigestSources` was generated empty.** oc-mirror 4.21 writes IDMS
   entries as `- mirrors:` first and `source:` second; the generator
   assumed the reverse and silently matched nothing. The handoff bundle
   would have shipped a blank `imageDigestSources:` — exactly the omission
   the docs call the most common cause of a hung disconnected bootstrap.
   Now parses both orderings and **refuses to emit an empty or mirror-less
   block**.
2. **`--quayRoot` does not hold the images.** Measured: 8 files, 32 KB. The
   images go to a podman volume under `$HOME`. Following the usual "point
   `--quayRoot` at a 500 GB partition" advice, you provision a large
   `/data` and then fill the root filesystem. Preflight now checks
   `podman info --format '{{.Store.GraphRoot}}'`.
3. **`oc adm release extract --authfile` is not a flag.** `oc` uses
   `-a/--registry-config`; only `oc-mirror` uses `--authfile`. Hard-failed
   the installer extraction, and the same error was in `oc adm release
   info` and `oc image info` in script and docs.
4. **`oadp-operator` is not a package.** It is **`redhat-oadp-operator`**,
   channel `stable`, not `stable-1.4`. Both wrong, inherited unverified
   from the source guide. Its bundles are named `oadp-operator.vX.Y.Z`,
   which is why the wrong name looks right.

### Would have aborted or hung a run

5. **Blocking `confirm` on a non-TTY.** The tmux advisory consumed EOF and
   died as `Aborted by user.`, killing a backgrounded push. `confirm` now
   refuses to prompt without a TTY; the tmux check is advisory only.
6. **`podman login` fell back to an interactive prompt**, hanging
   non-interactive runs and reporting it as `reading username: EOF`.
7. **`tar --exclude` placement.** GNU tar (RHEL 9) requires it *before* the
   path arguments; BSD tar (macOS, where this was written) is lenient.
   Under `set -e` this aborted packaging.
8. **Quay health race.** `mirror-registry install` reports success ~80 s
   before Quay serves traffic.
9. **A partial push died silently.** oc-mirror exits non-zero when some
   images fail but still generates cluster resources; `set -e` killed the
   script before it could report either. Now surfaces the error log and
   retry command, then exits non-zero.
10. **Removing `set -a` broke the composer.** The fix for the `REGISTRY_*`
    collision stopped exporting config, and the composer read
    `OCP_CHANNEL` via `os.environ` in a subprocess. Caught only by
    re-running the full flow.

### Wrong results or false alarms

11. **oc-mirror requires `umask 0022`** for *every* invocation, including
    the connected-side mirror — not just the registry install.
12. **Manifest lists broke the catalog check.** `oc image info` errors
    rather than reporting on a multi-arch image, so a healthy catalog was
    reported unpullable. Needs `--filter-by-os`.
13. **Signature artifacts are files, not a directory.** oc-mirror 4.21
    writes `signature-configmap.{json,yaml}`; upstream docs describe a
    `signatures/` directory. Verify check and `oc apply` instructions were
    both wrong.
14. **`REGISTRY_*` namespace collision.** Exporting `REGISTRY_HOST`/`PORT`
    made oc-mirror's embedded docker/distribution log `Ignoring
    unrecognized environment variable`. A recognised name would have
    silently reconfigured its internal registry.
15. **False-positive fapolicyd check.** Preflight probed `oc-mirror version
    --client`, invalid for that tool, reporting a working binary as broken.
16. **Binary install reported success without verifying** — printed an
    empty version string instead of failing.
17. **`oc-mirror list operators` does not work on a STIG host.** `list`,
    `describe` and `init` are v1-only and need `--v1`; the v1 path unpacks
    an embedded binary into a temp directory and execs it, which fapolicyd
    refuses. `TMPDIR` is honoured but does not help — the binary is
    untrusted wherever it lands. Replaced with `scripts/13-catalog.sh`.

### Incomplete output

18. **`oc` missing from the handoff bundle** — looked only in `binaries/`,
    but `oc` lives on `PATH`.
19. **`imageset-config.yaml` missing from the handoff bundle** — on the
    registry host it arrives with the archive, not in `config/`.
20. **The "binaries already transferred" marker was per-export.** It lived
    in the export directory, which is new every run, so each delta
    re-shipped ~840 MB of tooling. Moved to
    `${PREP_ROOT}/.binaries-transferred`.
21. **The size estimator sampled a heavy-tailed distribution** and swung
    2.5× between runs; see above.

### fapolicyd blocks interpreters, not just binaries

Worth separating out, because it constrains how this repo may be written.

fapolicyd governs `open` as well as `execute`, and its `%languages` policy
prevents an interpreter opening a script libmagic classifies as source
unless it is in the trust database:

| File | libmagic type | Result |
|---|---|---|
| `print(1)` | `text/plain` | runs |
| real script with imports/functions | Python source | **EPERM** |

A trivial test passes and a real helper fails, which sends you looking in
the wrong place. `fapolicyd-cli --file add` fixes one file; piping via
stdin avoids it entirely.

Every script here already uses `python3 - <<EOF`, so the repo is
unaffected — but shipping a `.py` helper would not work on a hardened host.
Recorded in `docs/02-fips-stig-rhel9.md` as a constraint for anyone
extending it.

### Not a bug, but worth knowing

A transient `405 METHOD NOT ALLOWED` on Quay's bearer-token endpoint failed
the first push at 3/202 images, and recurred on the delta push — so it is a
property of concurrency against a small registry host, not a one-off. Quay
was healthy throughout. Lowering to `--parallel-images 2 --parallel-layers
2` and re-running completed both. One multi-arch image (`support-tools`)
still failed on one architecture.

Retries are expensive: each push re-verifies the checksum (~5 min for
29 GB on 2 vCPU) and re-extracts the archive (~11 min). `SKIP_CHECKSUM=true`
and a `.checksum-verified` marker were added for this, and verified on the
delta retry.

### Also established

- **The dry-run gate does catch bad package names** — it fails with
  `collection error: no related images found` and writes no mapping. But it
  never names the offending package, which is why `13-catalog.sh --check`
  exists.
- **`oc image extract` needs a trailing slash** on a directory source path
  (`--path "/configs/:dest"`). Without it the command exits 0 and extracts
  nothing.
- **A `maxVersion` outside the channel is silently clamped.** `4.21.36`
  exists in the clients directory but not in the `stable-4.21` graph (73
  releases, head 4.21.34); oc-mirror mirrored one release without comment.
- **Quay's `_catalog` endpoint rejects basic auth** (401) — it requires the
  bearer-token flow. Verify content with `oc image info` by digest instead.
- **Mirrored operator images are digest-referenced, not tagged.** Checking
  `repo:latest` against the mirror fails even when the content is present.

## Not verified

Be explicit about the gaps.

- **A real cluster install from this mirror.** Out of scope for this repo;
  the handoff bundle has not been consumed by an installer. In particular
  the generated `imageDigestSources` is correct against the IDMS but has
  not been proven by booting an agent ISO.
- **`appendix-byo-registry.md`** — Artifactory/Harbor/Nexus paths are
  reasoned from documented behaviour, not executed.
- **Profiles are name/channel-validated** against the live v4.21 catalog
  (all 8 packages), and `virtualization`, `compliance-stig` and `gitops`
  have been resolved by a dry run or mirrored. `storage-lvms`,
  `backup-oadp` and `security-acs` have not been mirrored end to end, so
  their image counts and sizes are unmeasured.
- **Architectures other than `amd64`.**
- **Multi-segment archives.** `archiveSize` was never exceeded, so archive
  splitting is untested.
- **Recovery procedures** in `10-day2-delta.md` (lost archive, corrupted
  cache, cache restore from archives).
- **`oc-mirror delete` and Quay garbage collection.** The pruning workflow
  in `11-capacity-planning.md` is from upstream documentation and the
  observed `DEFAULT_TAG_EXPIRATION: 2w` setting; it has not been executed.
- **Capacity projections beyond the measured marginal costs.** The
  multi-year model extrapolates from one architecture and one content
  profile.

## Reproducing

```sh
cp config/prep.env.example config/prep.env   # edit for your environment
ROLE=connected ./scripts/00-preflight.sh
```

Then follow `README.md` in order.
