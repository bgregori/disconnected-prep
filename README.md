# disconnected-prep

Getting OpenShift content into an airgapped environment, on FIPS-enabled,
STIG-hardened RHEL 9.

This repository covers **preparation only**: everything from an
internet-connected bastion through to a populated, verified mirror registry
and a handoff bundle. It stops before `install-config.yaml`.

It is deliberately topology-agnostic. Single-node, three-node compact,
full multi-node, with or without virtualization — the preparation is the
same, and this repo is the part you do not want to rewrite per cluster.

## Scope

```
   CONNECTED BASTION                    REGISTRY HOST (disconnected)
   ┌──────────────────┐                ┌──────────────────────┐
   │ plan content     │                │ install Quay         │
   │ mirror to disk   │ ── transfer ─> │ push to registry     │
   │ package          │    (sneakernet)│ extract installer    │
   └──────────────────┘                │ verify ✓             │
                                       │ produce handoff      │
                                       └──────────┬───────────┘
                                                  │
   ══════════════ end of this repository ═════════╪═══════════
                                                  ▼
                                       install-config.yaml,
                                       agent ISO, day-2 cluster work
```

**In scope:** content selection, mirroring, transfer, registry, verification,
the FIPS/STIG workarounds that make the above actually run, and the Day-2
delta mirroring loop.

**Out of scope:** `install-config.yaml`, `agent-config.yaml`, ISO generation,
and anything that happens after a cluster exists. Prep hands those over as a
documented bundle — see [docs/08-handoff.md](docs/08-handoff.md).

## Start here

```sh
# ===== RUN ON: BOTH HOSTS =====
cp config/prep.env.example config/prep.env
${EDITOR} config/prep.env
```

Then work through the docs in order. Each has a matching script; the script
runs exactly the commands the doc shows, with the variables filled in.

| | Doc | Script | Where |
|---|---|---|---|
| 1 | [Prerequisites](docs/01-prerequisites.md) | `00-preflight.sh`, `10-fetch-binaries.sh` | both |
| 2 | [Plan your content](docs/02-plan-your-content.md) | `12-compose-imageset.sh`, `13-catalog.sh`, `15-dry-run.sh` | connected |
| 3 | [Mirror to disk](docs/03-connected-mirror.md) | `20-mirror-to-disk.sh` | connected |
| 4 | [Transfer](docs/04-transfer.md) | `30-package-transfer.sh` | connected |
| 5 | [Registry](docs/05-registry.md) | `40-stage-transfer.sh`, `50-install-registry.sh` | registry |
| 6 | [Push to registry](docs/06-push-to-registry.md) | `60-push-to-registry.sh` | registry |
| 7 | [Verify](docs/07-verify.md) | `70-extract-installer.sh`, `80-verify-mirror.sh` | registry |
| 8 | [Handoff](docs/08-handoff.md) | `90-handoff.sh` | registry |
| 9 | [Day-2 deltas](docs/09-day2-delta.md) | re-runs 2–6 | both |
| 10 | [Capacity planning](docs/10-capacity-planning.md) | `26-project-growth.sh` | planning |

The chapters carry the FIPS and STIG workarounds inline, at the step that
needs each one. [FIPS/STIG on RHEL 9](docs/appendix-fips-stig.md) is the
appendix explaining why they are there and what fails without them — read
it when something that should obviously work does not, not as a step of
its own.

Also: [troubleshooting](docs/troubleshooting.md) ·
[FIPS/STIG reference](docs/appendix-fips-stig.md) ·
[bring your own registry](docs/appendix-byo-registry.md) ·
[acceptance checklist](checklists/prep-acceptance.md) ·
[handoff contract](checklists/handoff-contract.md) ·
[validation record](VALIDATION.md)

## What has actually been tested

This repository was executed end-to-end against a genuinely airgapped,
FIPS-enabled, STIG-hardened RHEL 9.6 environment — including a real 29 GB
mirror of OpenShift 4.21.34 plus operators.

[VALIDATION.md](VALIDATION.md) records exactly what was run, the measured
numbers, the eight bugs that real-hardware testing exposed, and — equally
important — **what has not been verified**. Read it before relying on any
part of this for a production build.

## Done looks like

`./scripts/80-verify-mirror.sh` exits clean, and
`checklists/prep-acceptance.md` is fully ticked. At that point you hold:

- a mirror registry serving the release payload and every operator you chose
- `openshift-install-fips`, extracted from your own registry
- IDMS/ITMS/CatalogSource manifests for the cluster
- the CA bundle and pull secret the installer needs
- a `handoff/` directory containing all of the above plus
  ready-to-paste `install-config.yaml` fragments

## Documentation conventions

**The docs are self-contained. You do not need this repository to use it.**

That is deliberate: in many environments the repo cannot be carried into
the enclave, and the person doing the work is typing commands by hand from
a printed or PDF copy. Every chapter therefore shows the real commands,
with the variables written out. Where a chapter offers a script, it also
shows what that script runs, under a **"By hand"** heading. Following the
docs alone produces exactly the same result.

**Every code block says where to run it**, on its first line:

```sh
# ===== RUN ON: CONNECTED BASTION =====
oc-mirror --v2 --config config/imageset-config.yaml file://./mirror-out
```

The marker is inside the block rather than above it so that it survives a
copy-paste into a terminal, a runbook or a change request. Running the
right command on the wrong host is the most common way these procedures go
wrong, and the two hosts hold deliberately similar directory trees, so
`~/ocp-airgap/binaries` looks correct on either one.

The labels used are `CONNECTED BASTION`, `REGISTRY HOST`, `BOTH HOSTS`,
`A NODE-NETWORK HOST` (for checks that must *not* run on the registry host,
because resolving a name there proves nothing about the cluster),
`THE CLUSTER` for the install side, and `THE ISO-GENERATING HOST` for the
one FIPS check that belongs wherever `openshift-install-fips` runs. Blocks
that are file content rather than commands are marked `EDIT IN:` instead.

Scripts are a convenience for repeat runs, not the product. They contain no
hidden logic and echo every command before executing it, so the terminal
transcript doubles as evidence of what was run — which matters when the
build has to be justified for accreditation.

Scripts are numbered to sort into execution order, with gaps for insertions.
Odd-numbered scripts are optional (dry run, size estimate, catalog queries).

If you are working without the repo, the two chapters to read closely are
[02 — plan your content](docs/02-plan-your-content.md), which includes a
complete ImageSetConfiguration you can type, and
[08 — handoff](docs/08-handoff.md), which shows how to build
`imageDigestSources` from the generated IDMS without the helper script.

Markers used throughout:

> ⚠️ **STIG** — a step that exists only because of hardening, and that will
> fail confusingly on a hardened host if skipped.

> 📌 **Handoff** — something the install side must be told. Collected in
> [docs/08-handoff.md](docs/08-handoff.md).

## Versions

Written against OpenShift 4.21 and `oc-mirror` **v2**. The `--v2` flag is on
every invocation; v1 is deprecated and its flags are not interchangeable.

Behaviour described here was verified against the upstream `oc-mirror`
documentation and source in `reference/`. Where a detail is version-sensitive
it is called out inline.

To target a different OpenShift version, change `OCP_VERSION` and
`OCP_CHANNEL` in `config/prep.env` — nothing else should need editing.
