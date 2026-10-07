# Appendix: bring your own registry

Using an existing enterprise registry — Artifactory, Harbor, Nexus, or an
existing Quay — instead of `mirror-registry`.

Common in accredited environments, where a hardened registry already exists
and standing up another one is a paperwork exercise rather than a technical
one.

This replaces [06-registry.md](06-registry.md). Everything else in the repo
is unchanged.

---

## Requirements

Your registry must:

- Speak **Docker Registry HTTP API v2**. All four above do.
- Allow **pushing arbitrary repository paths**. `oc-mirror` creates
  repositories mirroring upstream structure — `openshift/release-images`,
  `redhat/redhat-operator-index`, and so on.
- Serve a **TLS certificate the push host and cluster nodes trust**.
- Be **reachable from the cluster nodes**, not only the host you push from.
- Have **capacity**, with headroom for Day-2 updates.

It does **not** need to be airgapped itself, though in most such
environments it is.

---

## Configure

In `config/prep.env`:

```sh
# ===== EDIT IN: config/prep.env on the HOST YOU PUSH FROM =====
REGISTRY_HOST="artifactory.corp.local"
REGISTRY_PORT="443"
# QUAY_ROOT, QUAY_USER, QUAY_PASSWORD are unused -- skip 50-install-registry.sh
```

### Credentials

Write the auth file by hand instead of letting `50-install-registry.sh`
generate it:

```sh
# ===== RUN ON: THE HOST YOU PUSH FROM =====
AUTH=$(printf '%s:%s' "${REG_USER}" "${REG_TOKEN}" | base64 -w0)
cat > ~/ocp-airgap/binaries/mirror-pull-secret.json <<EOF
{"auths":{"artifactory.corp.local:443":{"auth":"${AUTH}"}}}
EOF
chmod 600 ~/ocp-airgap/binaries/mirror-pull-secret.json
```

The key must match the `docker://` target **exactly**. If you push to
`docker://artifactory.corp.local` without a port, the key must have no
port either.

Prefer a token or service account over a personal login — this credential
ends up in automation and in the cluster pull secret.

### Certificate trust

If the registry uses an internal CA:

```sh
# ===== RUN ON: THE HOST YOU PUSH FROM =====
sudo cp corp-root-ca.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
curl -I https://artifactory.corp.local/v2/
```

📌 **Handoff** That CA, not a Quay-generated one, is what goes into
`additionalTrustBundle`. `90-handoff.sh` reads from `${QUAY_ROOT}` — point
it at your CA or assemble the fragment by hand.

---

## Push

Unchanged except for the destination:

```sh
# ===== RUN ON: THE HOST YOU PUSH FROM =====
oc-mirror --v2 \
  --config imports/<tag>/imageset-config.yaml \
  --from file:///home/user/ocp-airgap/imports/<tag> \
  --cache-dir ./cache \
  --authfile binaries/mirror-pull-secret.json \
  docker://artifactory.corp.local
```

---

## Registry-specific notes

### Path depth limits

Artifactory and Harbor often restrict how deeply repositories may nest.
`oc-mirror` otherwise creates paths that exceed those limits.

```sh
# ===== RUN ON: THE HOST YOU PUSH FROM =====
oc-mirror --v2 --max-nested-paths 2 ...
```

In `config/prep.env`:

```sh
# ===== EDIT IN: config/prep.env on the HOST YOU PUSH FROM =====
USE_MAX_NESTED_PATHS="true"
MAX_NESTED_PATHS="2"
```

Set this on the **first** push. Changing it later rewrites every image path,
invalidating the IDMS already applied to a cluster.

### Harbor projects

Harbor requires a project to exist before a push. `oc-mirror` will not
create one.

Create projects matching the top-level path segments it uses — typically
`openshift`, `redhat`, `rhel8`, `rhel9`, `container-native-virtualization`.
Check against the dry-run mapping:

```sh
# ===== RUN ON: THE HOST YOU PUSH FROM =====
awk -F'=' '{print $2}' mirror-out/working-dir/dry-run/mapping.txt \
  | sed 's|.*://||; s|/.*||' | sort -u
```

Or enable automatic project creation if policy permits it.

### Artifactory

Use a **Docker** repository, not a generic one. A virtual repository
aggregating a local repo works, but push must target the local repo
directly.

Artifactory's Docker v2 implementation can be sensitive to concurrency:

```sh
--parallel-images 2 --parallel-layers 2
```

### Nexus

Enable the Docker Bearer Token realm, or authentication fails in a way that
looks like bad credentials.

Nexus needs a distinct HTTPS connector port for Docker, separate from the
main UI port — set `REGISTRY_PORT` to the Docker connector.

### Existing Quay

Works unmodified. Create an organization matching the top-level path
segments, or enable automatic repository creation for the push account.

---

## Quota and retention

The common and painful failure: a registry with a retention policy that
deletes untagged manifests or old images.

`oc-mirror` pushes many digest-referenced images with no tags. A cleanup
policy that prunes untagged manifests **will break your cluster**, and the
symptom is pods failing to pull at arbitrary later times.

Before mirroring, confirm with the registry owner:

- Untagged manifests are **exempt** from cleanup for these repositories.
- No age-based retention applies.
- The quota covers current content plus Day-2 growth.

Get this in writing. It is the one failure mode of a shared registry that
prep cannot verify and cannot defend against.

---

## Verification

`80-verify-mirror.sh` works unchanged — it reads `REGISTRY_HOST` and
`REGISTRY_PORT`. Its CA-trust check exercises your corporate chain rather
than a Quay-generated one.

The manual check in [08-verify.md](08-verify.md) matters more here: confirm
resolution and pull **from the node network**, since an enterprise registry
is more likely than a local Quay to sit behind firewalls or load balancers
the nodes see differently from the host you push from.
