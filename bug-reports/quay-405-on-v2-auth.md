# Quay returns 405 on `GET /v2/auth` during a large push

**Status:** reproduced on three independent clean builds. Root cause not
isolated. Filed here so the evidence is not lost; see *Open questions*
before sending this anywhere.

## Summary

During a large `oc-mirror` disk-to-mirror push into a `mirror-registry`
Quay, a small number of `GET /v2/auth` requests are answered `405 METHOD
NOT ALLOWED`. The client reports the failure as

```
error mirroring image registry.redhat.io/rhel9/support-tools:latest
  error: copying image 1/4 from manifest list: trying to reuse blob
  sha256:… at destination: Requesting bearer token:
  received unexpected HTTP status: 405 METHOD NOT ALLOWED
```

which reads as a TLS or credentials problem and is neither. The affected
images are reported as not mirrored; re-running the push copies them
successfully.

## Environment

| | |
|---|---|
| Quay | `registry.redhat.io/quay/quay-rhel8:v3.8.12` (via `mirror-registry` 1.3.9) |
| Host | RHEL 9.6, FIPS enabled, SELinux enforcing, STIG-hardened |
| Client | `oc-mirror` v2, `4.21.0-202609221210.p2.g4b703bb` |
| Content | OpenShift 4.21.34 payload, 2 operators, 3 additional images (203 total) |
| Storage | rootless podman, graphroot relocated to a dedicated volume |

## Observed

Verbatim, from `podman logs quay-app`:

```
gunicorn-registry stdout | 2026-10-09 21:11:54,884 [179] [INFO] [gunicorn.access]
169.254.1.2 - init [09/Oct/2026:21:11:54 +0000]
"GET /v2/auth?account=init&scope=repository%3Aopenshift4%2Fose-must-gather%3Apull%2Cpush
&service=registry.ocp.sandbox972.opentlc.com%3A8443 HTTP/1.1" 405 87 "-" "oc-mirror"
```

Across one full push:

- **4 × `405`** against **1,644 × `200`** on the same endpoint
- every `405` carried `scope=repository:<ns>/<repo>:pull,push`
- all were confined to `openshift4/ose-must-gather` and `rhel9/support-tools`
- both are **multi-architecture manifest lists** (`copying image 1/4 from
  manifest list`), and both were being pushed into namespaces that did not
  previously exist
- the 192 release images and 8 operator images, in namespaces created
  earlier in the same run, never saw a `405`
- **no traceback or application error** accompanies the `405` — it appears
  to come from routing, not from handler code

Reproduced on three separate freshly provisioned environments, always on
the first push, always on the same class of image.

## Not reproducible by

Eight concurrent `GET /v2/auth` requests for a brand-new namespace scope,
issued directly with `curl`, returned `200` eight times out of eight. The
same against an existing namespace also returned `200` eight times. So
concurrent token requests alone do not trigger it; a concurrent push
appears to be required.

## Impact

The push exits non-zero and the summary reports the images as unmirrored.
On an airgapped build this is a multi-hour feedback loop: a retry
re-extracts the entire archive (29 GB here, ~11 minutes) before reaching
anything it can skip.

## Workaround

Re-run the push. The same images succeed on the second attempt.

## Open questions

1. Why `405` rather than `401`/`500`? In a Flask/Werkzeug application a
   `405` normally means the URL matched a rule whose method set excludes
   the request method — which would suggest the `/v2/` blueprint, or that
   route, was briefly not registered or disabled, rather than anything
   specific to namespaces.
2. Does Quay disable the `/v2/` blueprint transiently — under load, during
   a read-only window, or while a worker initialises?
3. Is the namespace-creation correlation causal, or an artefact of those
   images being pushed last and being the only multi-arch ones?
4. Does `--parallel-images 1` for a first push avoid it? Cheaper than a
   retry if so.
5. Is this fixed in a Quay newer than 3.8.12? `mirror-registry` 1.3.9
   pins an old Quay; the bug may not exist upstream.

Answering (2) and (5) would decide whether this is worth filing against
Quay at all.
