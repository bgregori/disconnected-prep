#!/usr/bin/env bash
# docs/01-prerequisites.md -- preflight checks
# Run on: CONNECTED bastion (ROLE=connected) or DISCONNECTED bastion (ROLE=disconnected)
#
#   ROLE=connected    ./scripts/00-preflight.sh
#   ROLE=disconnected ./scripts/00-preflight.sh
#
# Checks only. Changes nothing.

source "$(dirname "$0")/lib/common.sh"
load_env

ROLE="${ROLE:-connected}"
failures=0
check() { if "$@"; then :; else failures=$((failures+1)); fi; }

info "Preflight for role: ${ROLE}"

# --- OS --------------------------------------------------------------------

if [[ -r /etc/redhat-release ]]; then
  ok "OS: $(cat /etc/redhat-release)"
  grep -qE 'release 9' /etc/redhat-release || warn "Not RHEL 9 -- these procedures are only tested on RHEL 9."
else
  warn "Not a Red Hat host. The FIPS/STIG workarounds in docs/02 assume RHEL 9."
fi

# --- FIPS ------------------------------------------------------------------

if [[ -r /proc/sys/crypto/fips_enabled ]]; then
  if [[ "$(cat /proc/sys/crypto/fips_enabled)" == "1" ]]; then
    ok "Bastion FIPS mode: enabled"
  else
    info "Bastion FIPS mode: disabled (this is fine -- cluster FIPS is set in install-config.yaml)"
  fi
fi

# --- STIG-related blockers -------------------------------------------------

current_umask=$(umask)
if [[ "${current_umask}" != "0022" ]]; then
  warn "umask is ${current_umask}. Two things break at this setting:"
  warn "  - oc-mirror warns 'Detected bad umask' and writes unreadable cache/archive content"
  warn "  - mirror-registry creates Quay config dirs the container cannot read"
  warn "  -> the scripts relax it per-run; see docs/02-fips-stig-rhel9.md"
fi

if command -v fapolicyd >/dev/null 2>&1 && systemctl is-active --quiet fapolicyd 2>/dev/null; then
  info "fapolicyd is active. Binaries must be allowlisted before they will run."
  # Each tool needs its own version invocation -- `oc-mirror version` requires
  # --v2, so probing it with --client gives a false "will not execute".
  if command -v oc >/dev/null 2>&1; then
    oc version --client >/dev/null 2>&1 \
      && ok "oc executes under fapolicyd" \
      || { warn "oc is on PATH but will not execute. Run scripts/10-fetch-binaries.sh."; failures=$((failures+1)); }
  fi
  if command -v oc-mirror >/dev/null 2>&1; then
    (umask 0022; oc-mirror version --v2 >/dev/null 2>&1) \
      && ok "oc-mirror executes under fapolicyd" \
      || { warn "oc-mirror is on PATH but will not execute. Run scripts/10-fetch-binaries.sh."; failures=$((failures+1)); }
  fi
fi

if command -v getenforce >/dev/null 2>&1; then
  info "SELinux: $(getenforce)"
fi

# --- tooling ---------------------------------------------------------------

if [[ "${ROLE}" == "connected" ]]; then
  check require_cmds oc oc-mirror curl tar
else
  check require_cmds oc oc-mirror tar
fi

# --- oc-mirror local storage port -----------------------------------------

if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${OC_MIRROR_PORT:-55000} "; then
  die "Port ${OC_MIRROR_PORT:-55000} is in use. oc-mirror needs it for its local storage instance."
else
  ok "Port ${OC_MIRROR_PORT:-55000} available for oc-mirror local storage"
fi

# --- disk ------------------------------------------------------------------

if [[ "${ROLE}" == "connected" ]]; then
  check require_space "${CACHE_DIR}"  "${MIN_CACHE_GB:-150}"
  check require_space "${MIRROR_OUT}" "${MIN_OUTPUT_GB:-150}"
  # Only a problem when /home is actually a separate (and usually small)
  # filesystem, which is a common but not universal STIG layout.
  cache_mnt=$(df -P "$(dirname "${CACHE_DIR}")" 2>/dev/null | tail -1 | awk '{print $NF}')
  if [[ "${CACHE_DIR}" == "${HOME}"* && "${cache_mnt}" != "/" ]]; then
    warn "CACHE_DIR is under \$HOME on a separate filesystem (${cache_mnt}); confirm it is not quota'd."
  fi
else
  # Quay image data lives in a podman volume, NOT under --quayRoot.
  # quayRoot holds only config and certs (~32 KB measured), so checking it
  # for hundreds of GB tells you nothing useful.
  if command -v podman >/dev/null 2>&1; then
    graph_root=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)
    if [[ -n "${graph_root}" ]]; then
      info "podman storage root: ${graph_root}  <- Quay images land here"
      check require_space "${graph_root}" "${MIN_QUAY_GB:-200}"
      graph_mnt=$(df -P "${graph_root}" 2>/dev/null | tail -1 | awk '{print $NF}')
      if [[ "${graph_mnt}" == "/" ]]; then
        warn "Quay images will be written to the ROOT filesystem (${graph_mnt})."
        warn "  Filling / takes the host down, not just the registry."
        warn "  To relocate, set graphroot in ~/.config/containers/storage.conf"
        warn "  BEFORE installing -- see docs/06-registry.md"
      fi
    else
      warn "Could not determine podman storage root; check it manually."
    fi
  fi
  # quayRoot needs to exist and be durable, but only needs megabytes.
  check require_space "${QUAY_ROOT}"   "${MIN_QUAYROOT_GB:-1}"
  check require_space "${IMPORTS_DIR}" "${MIN_IMPORT_GB:-100}"
  check require_space "${CACHE_DIR}"   "${MIN_CACHE_GB:-150}"
fi

# --- credentials -----------------------------------------------------------

if [[ "${ROLE}" == "connected" ]]; then
  if [[ -f "${RH_PULL_SECRET}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      if jq -e '.auths["registry.redhat.io"]' "${RH_PULL_SECRET}" >/dev/null 2>&1; then
        ok "Pull secret present and contains registry.redhat.io"
      else
        warn "Pull secret has no registry.redhat.io entry -- operator mirroring will fail."
        failures=$((failures+1))
      fi
    else
      ok "Pull secret present at ${RH_PULL_SECRET} (install jq for content validation)"
    fi
  else
    warn "Missing ${RH_PULL_SECRET}"; failures=$((failures+1))
  fi

  info "Testing upstream registry reachability"
  for r in registry.redhat.io quay.io mirror.openshift.com; do
    if curl -sSf -m 10 -o /dev/null "https://${r}/" 2>/dev/null \
       || curl -sS -m 10 -o /dev/null -w '%{http_code}' "https://${r}/" 2>/dev/null | grep -qE '^[234]'; then
      ok "reachable: ${r}"
    else
      warn "unreachable: ${r}"; failures=$((failures+1))
    fi
  done
fi

# --- imageset config -------------------------------------------------------

if [[ "${ROLE}" == "connected" ]]; then
  if [[ -f "${IMAGESET_CONFIG}" ]]; then
    ok "ImageSetConfiguration present: ${IMAGESET_CONFIG}"
  else
    warn "No ImageSetConfiguration at ${IMAGESET_CONFIG}"
    warn "  -> build one: see docs/03-plan-your-content.md"
    failures=$((failures+1))
  fi
fi

# --- registry hostname sanity ---------------------------------------------

if [[ "${REGISTRY_HOST}" != *.* ]]; then
  warn "REGISTRY_HOST='${REGISTRY_HOST}' has no dot. oc-mirror parses an unqualified"
  warn "  docker:// target as a repository name, not a hostname. Use an FQDN."
  failures=$((failures+1))
fi

echo >&2
if (( failures == 0 )); then
  ok "Preflight passed."
else
  die "${failures} preflight problem(s). Resolve these before mirroring."
fi
