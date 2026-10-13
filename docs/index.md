---
title: disconnected-prep
description: >-
  A tested, self-contained procedure for getting OpenShift content across an air gap —
  content planning, oc-mirror v2, transfer, mirror registry, verification, and a handoff
  bundle — on FIPS-enabled, STIG-hardened RHEL 9.
hero: true
hero_title: OpenShift content, across the air gap
hero_tagline: >-
  Plan what to mirror, carry it over, stand up the registry, and hand the install team a
  bundle you have actually verified. Written for FIPS-enabled, STIG-hardened RHEL 9,
  where the standard mirroring documentation quietly stops working.
---

**disconnected-prep** is the preparation half of a disconnected OpenShift install: everything
from an internet-connected bastion through to a populated, verified mirror registry and a
handoff bundle. It is a procedure first and a set of scripts second — every command is
written out in the chapters, so the work can be done by hand, from a printout, by someone
who cannot carry this repository into the enclave.

> **Preparation only.** This site stops at `install-config.yaml`. It is deliberately
> topology-agnostic — single-node, three-node compact, full multi-node, with or without
> OpenShift Virtualization — because the preparation is identical in all four cases, and
> this is the part you do not want to rewrite per cluster.

---

## What it covers

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
{: .diagram}

| | |
|---|---|
| **Content selection** | A base `ImageSetConfiguration` plus opt-in profiles — virtualization, LVM storage, GitOps, ACS, OADP, compliance — composed into the one file that decides what exists inside the enclave forever. |
| **Mirroring and transfer** | `oc-mirror --v2` to disk, packaged into a dated, checksummed bundle sized for whatever actually crosses the gap. |
| **The registry** | Red Hat `mirror-registry` (standalone Quay) stood up, its CA trusted, its auth file written — or [your existing enterprise registry](appendix-byo-registry.md) instead. |
| **Verification** | A gate, not a formality: the release payload, every operator you chose, the extracted installer, and the generated IDMS/ITMS manifests, all checked against the registry you just populated. |
| **Handoff** | A directory the install team can consume, with ready-to-paste `install-config.yaml` fragments, the CA bundle, and the pull secret. |
| **The hardening tax** | The FIPS and STIG workarounds — `fapolicyd`, SELinux, `umask`, Quay file modes — inline at the step that needs each one, because on a hardened host the documented procedure fails without them. |
{: .pairs}

---

## Who it is for

Anyone standing up OpenShift where the cluster cannot reach the internet: classified and
accredited networks, regulated industry, OT and edge sites, and the rehearsal environments
built to imitate them.

It assumes you are comfortable on RHEL and with `oc`, and that you have a Red Hat pull
secret. It does not assume you have done a disconnected install before — the decisions that
are hard to reverse are called out where you make them, not after.

---

## How to use these docs

**Read the chapters in order the first time.** Each one ends where the next begins, and
chapter 1 leaves you with the tooling every later chapter assumes.

**The docs are self-contained — you do not need the repository to use them.** In many
environments the repo cannot come into the enclave, and the person doing the work is
typing commands from a PDF. So every chapter shows the real commands with the variables
written out, and where a chapter offers a script it also shows what that script runs,
under a **By hand** heading. Following the docs alone produces exactly the same result.

### Two ways to work

| | What you do | Best when |
|---|---|---|
| **Scripts** | `./scripts/NN-*.sh`, configured once through `config/prep.env`. | You can get the repo onto the hosts, and you expect to repeat the run — a rehearsal, a second site, a day-2 delta. |
| **By hand** | Copy each block out of the chapter and run it. | The repo cannot cross the gap, or every command has to be justified and recorded individually. |

Scripts contain no hidden logic and echo every command before running it, so the terminal
transcript doubles as evidence of what was run — which matters when the build has to be
justified for accreditation. They are numbered to sort into execution order; odd-numbered
ones are optional (dry run, size estimate, catalog queries).

### Conventions

**Every code block says where to run it**, on its first line:

```sh
# ===== RUN ON: CONNECTED BASTION =====
oc-mirror --v2 --config config/imageset-config.yaml file://./mirror-out
```

The marker lives inside the block so it survives a copy-paste into a terminal, a runbook,
or a change request. Running the right command on the wrong host is the most common way
these procedures go wrong, and the two hosts hold deliberately similar directory trees.
The labels are `CONNECTED BASTION`, `REGISTRY HOST`, `BOTH HOSTS`, `A NODE-NETWORK HOST`,
`THE CLUSTER`, and `THE ISO-GENERATING HOST`; blocks that are file content rather than
commands say `EDIT IN:` instead.

**Paths are written as `${OCP_AIRGAP_ROOT}`, which you choose.** The chapters never assume
the prep tree is in your home directory, because on a hardened build `/home` is usually its
own undersized file system. You export it once per host, durably, and every later block
uses it. By-hand blocks that depend on it open with a guard that turns an unset variable
into a stop rather than a run against `/root`:

```sh
# ===== RUN ON: REGISTRY HOST =====
: "${OCP_AIRGAP_ROOT:?set it first -- see 01-prerequisites.md}"
```

Two markers appear throughout:

> ⚠️ **STIG** — a step that exists only because of hardening, and that will fail
> confusingly on a hardened host if skipped.

> 📌 **Handoff** — something the install side must be told. All of them are collected in
> [chapter 8](08-handoff.md).

---

## The chapters

| # | Chapter | What happens | Where |
|---|---|---|---|
| 1 | [Prerequisites](01-prerequisites.md) | Hosts, disk, FIPS, credentials, DNS, tooling. Two of these are expensive to fix later. | <span class="host host--both">both</span> |
| 2 | [Plan your content](02-plan-your-content.md) | The `ImageSetConfiguration`. The most consequential step in prep, and the one most often rushed. | <span class="host host--connected">connected</span> |
| 3 | [Mirror to disk](03-connected-mirror.md) | `oc-mirror --v2` pulls the release payload and every operator you chose into archives. | <span class="host host--connected">connected</span> |
| 4 | [Transfer](04-transfer.md) | Package and checksum the bundle. Short chapter, longest feedback loop when it goes wrong. | <span class="host host--connected">connected</span> |
| 5 | [Mirror registry](05-registry.md) | Install `mirror-registry`, trust its CA, write the auth file used for the push. | <span class="host host--registry">registry</span> |
| 6 | [Push to registry](06-push-to-registry.md) | Unpack the archives into Quay and generate the cluster manifests. | <span class="host host--registry">registry</span> |
| 7 | [Verify](07-verify.md) | The gate. Nothing goes to the install team until this passes. | <span class="host host--registry">registry</span> |
| 8 | [Handoff](08-handoff.md) | The boundary: prep produces a bundle, the install side consumes it. | <span class="host host--registry">registry</span> |
| 9 | [Day-2 deltas](09-day2-delta.md) | A z-stream bump or a new operator later — tens of gigabytes instead of hundreds, if you reuse the state. | <span class="host host--both">both</span> |
| 10 | [Capacity planning](10-capacity-planning.md) | Sizing for year three. A mirror registry is not a cache: nothing expires, nothing shrinks. | <span class="host host--both">planning</span> |
{: .chapters}

Alongside them: [troubleshooting](troubleshooting.md), organised by the error you are
seeing; [FIPS and STIG on RHEL 9](appendix-fips-stig.md), which explains why the
hardening workarounds exist and what fails without each one; and [bring your own
registry](appendix-byo-registry.md), which replaces chapter 5 when a hardened enterprise
registry already exists.

---

## Getting started

### 1. Check the prerequisites

You need two hosts — one with internet access, one that can reach the disconnected
network — a Red Hat pull secret, and a resolvable FQDN for the registry. Budget roughly
**55 GiB** free on the connected bastion and **85 GiB** on the registry host for a single
29 GB mirror, and read [chapter 1](01-prerequisites.md) before provisioning either: disk
layout and FIPS mode are the two things that are painful to change afterwards.

### 2. Choose where the prep tree lives

```sh
# ===== RUN ON: BOTH HOSTS =====
export OCP_AIRGAP_ROOT="/data/ocp-airgap"
```

Everything else derives from this one path. Put it on the volume you provisioned for it,
not in `/home`, and make the export durable — see
[where the prep tree lives](01-prerequisites.md#where-the-prep-tree-lives).

### 3. Configure the repository, if you are using it

```sh
# ===== RUN ON: BOTH HOSTS =====
git clone https://github.com/bgregori/disconnected-prep.git
cd disconnected-prep
cp config/prep.env.example config/prep.env
chmod 600 config/prep.env          # it will hold the Quay password
${EDITOR} config/prep.env
```

Set `OCP_VERSION` and `OCP_CHANNEL` to the exact z-stream you intend to install, and the
registry hostname and credentials. An exported `OCP_AIRGAP_ROOT` wins over the value in
the file, so the by-hand path and the script path stay one variable rather than two.

Working without the repo? Skip this step. [Chapter 1](01-prerequisites.md) sets the same
values as plain exports, and every later block uses them by name.

### 4. Decide what to mirror before you mirror anything

Anything you leave out is not installable inside the enclave, and adding it later means
another trip across the gap — which on a classified network can be days of scheduling for
a five-minute mistake. [Chapter 2](02-plan-your-content.md) walks the decision and ends
with a complete `ImageSetConfiguration` you can type out if you have to.

### 5. Work the chapters in order

With the repo, the whole run is thirteen commands. They are listed here so you can see the
shape of it — run them from the chapters, which explain what each one is about to do and
what the output should look like:

```sh
# ===== RUN ON: CONNECTED BASTION =====
ROLE=connected ./scripts/00-preflight.sh
./scripts/10-fetch-binaries.sh
./scripts/12-compose-imageset.sh
./scripts/15-dry-run.sh                 # optional, and worth it
./scripts/20-mirror-to-disk.sh
./scripts/30-package-transfer.sh
```

```sh
# ===== RUN ON: REGISTRY HOST =====
./scripts/40-stage-transfer.sh          # first transfer only
ROLE=disconnected ./scripts/00-preflight.sh
./scripts/50-install-registry.sh
./scripts/60-push-to-registry.sh
./scripts/70-extract-installer.sh
./scripts/80-verify-mirror.sh
./scripts/90-handoff.sh
```

[Start with chapter 1 →](01-prerequisites.md)

---

## Done looks like

`80-verify-mirror.sh` exits clean and the
[acceptance checklist](https://github.com/bgregori/disconnected-prep/blob/main/checklists/prep-acceptance.md)
is fully ticked. At that point you hold:

- a mirror registry serving the release payload and every operator you chose
- `openshift-install-fips`, extracted from your own registry rather than downloaded
- IDMS, ITMS, and CatalogSource manifests for the cluster
- the CA bundle and pull secret the installer needs
- a `handoff/` directory containing all of the above, plus ready-to-paste
  `install-config.yaml` fragments

What the install side is owed, exactly, is written down as a
[handoff contract](https://github.com/bgregori/disconnected-prep/blob/main/checklists/handoff-contract.md).

---

## What has actually been tested

This procedure was executed end-to-end against a genuinely air-gapped, FIPS-enabled,
STIG-hardened RHEL 9.6 environment, including a real 29 GB mirror of OpenShift 4.21.34
plus operators.

[VALIDATION.md](https://github.com/bgregori/disconnected-prep/blob/main/VALIDATION.md)
records what was run, the measured numbers, the eight bugs that real-hardware testing
exposed, and — equally important — **what has not been verified**. Read it before relying
on any part of this for a production build.

Everything here is written against OpenShift 4.21 and `oc-mirror` **v2**; the `--v2` flag
is on every invocation, because v1 is deprecated and its flags are not interchangeable. To
target a different version, change `OCP_VERSION` and `OCP_CHANNEL` — nothing else should
need editing.
