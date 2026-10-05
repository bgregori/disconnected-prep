# ImageSetConfiguration profiles

Composable fragments assembled into a single ImageSetConfiguration by
`scripts/12-compose-imageset.sh`.

```sh
./scripts/12-compose-imageset.sh                 # list profiles
./scripts/12-compose-imageset.sh virtualization storage-lvms compliance-stig
```

`base-platform.yaml` is always included.

---

## Profiles

| Profile | Adds |
|---|---|
| `base-platform.yaml` | Release payload, diagnostics. Always included. |
| `virtualization` | CNV, nmstate, guest boot sources, virtio-win |
| `storage-lvms` | LVM Storage — local disk, single-node/edge |
| `compliance-stig` | Compliance Operator, File Integrity Operator |
| `backup-oadp` | OADP / Velero |
| `gitops` | OpenShift GitOps (Argo CD) |
| `security-acs` | Advanced Cluster Security |

**Read the profile file, not just the row above.** Several document
obligations they create for the install side — `virtualization.yaml` in
particular describes behaviour that is not discoverable later and will stall
an evaluation if missed.

---

## How assembly works

Fragments are plain text delimited by section markers:

```yaml
# >>> operators
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v${OCP_MINOR}
      packages:
        - name: my-operator
          channels:
            - name: stable
# <<< operators

# >>> additionalImages
    - name: registry.redhat.io/example/image:latest
# <<< additionalImages
```

Recognised sections: `header`, `platform`, `operators`, `additionalImages`.

The composer collects each section across all selected fragments, merges
operator entries that share a catalog into one, and emits the surrounding
YAML. Comments are preserved so the generated file explains itself.

No YAML library is required — registry hosts frequently lack PyYAML.

### Variables

Substituted from `config/prep.env`:

| Variable | From | Example |
|---|---|---|
| `${OCP_VERSION}` | `OCP_VERSION` | `4.21.26` |
| `${OCP_CHANNEL}` | `OCP_CHANNEL` | `stable-4.21` |
| `${OCP_ARCH}` | `OCP_ARCH` | `amd64` |
| `${OCP_MINOR}` | derived | `4.21` |

`${OCP_MINOR}` is for catalog tags (`redhat-operator-index:v4.21`) and
version-tracking channels (`stable-4.21`).

---

## Adding a profile

Create `profiles/<name>.yaml`:

```yaml
# Summary: one line -- shown by the composer's listing.
#
# Why someone would want this, what it costs, and anything it obliges the
# install side to do. Write the obligations down; this file is where whoever
# chooses the profile will actually look.

# >>> operators
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v${OCP_MINOR}
      packages:
        - name: your-operator
          channels:
            - name: stable
# <<< operators
```

Verify the package name and channel against the real catalog first:

```sh
oc-mirror list operators \
  --catalog=registry.redhat.io/redhat/redhat-operator-index:v4.21 \
  --package=your-operator --v2
```

Channel naming is not consistent across operators — `stable`, `stable-4.21`,
`stable-1.4` and `latest` all occur. Do not assume.

---

## Editing the generated file

`${IMAGESET_CONFIG}` is yours. Hand-edit it freely.

Re-running the composer overwrites it, so put changes you want to keep into
a profile — or stop re-running the composer and maintain the file directly.
Both are reasonable; the composer is a starting point, not a dependency.

---

## Sizing

```yaml
archiveSize: 100     # GB per archive segment
```

Set in `base-platform.yaml`. Match it to your transport medium. Add
`--strict-archive` to fail rather than exceed the limit when a single file
is larger than a segment.

Check the real cost before mirroring:

```sh
./scripts/15-dry-run.sh
```
