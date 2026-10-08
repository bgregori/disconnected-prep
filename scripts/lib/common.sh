#!/usr/bin/env bash
# Shared helpers. Sourced by every script in scripts/.
#
# Deliberately minimal: this library adds variable loading, logging and
# preflight assertions. It does not wrap, retry, or reinterpret any
# oc-mirror / oc / mirror-registry command. Every command these scripts run
# is echoed verbatim before execution so the terminal transcript is an
# accurate record of what happened on the host.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# --- output ----------------------------------------------------------------

if [[ -t 2 ]]; then
  _c_red=$'\033[31m'; _c_yellow=$'\033[33m'; _c_green=$'\033[32m'
  _c_blue=$'\033[34m'; _c_reset=$'\033[0m'
else
  _c_red=''; _c_yellow=''; _c_green=''; _c_blue=''; _c_reset=''
fi

info()  { printf '%s[INFO]%s  %s\n'  "${_c_blue}"   "${_c_reset}" "$*" >&2; }
warn()  { printf '%s[WARN]%s  %s\n'  "${_c_yellow}" "${_c_reset}" "$*" >&2; }
ok()    { printf '%s[ OK ]%s  %s\n'  "${_c_green}"  "${_c_reset}" "$*" >&2; }
die()   { printf '%s[FAIL]%s  %s\n'  "${_c_red}"    "${_c_reset}" "$*" >&2; exit 1; }

# Echo a command, then run it. The echoed line is copy-pasteable.
run() {
  printf '%s+%s %s\n' "${_c_green}" "${_c_reset}" "$*" >&2
  "$@"
}

# Same, but for commands that must run through a shell (pipes, redirects).
run_sh() {
  printf '%s+%s %s\n' "${_c_green}" "${_c_reset}" "$1" >&2
  bash -c "$1"
}

# --- configuration ---------------------------------------------------------

load_env() {
  local env_file="${REPO_ROOT}/config/prep.env"
  [[ -f "${env_file}" ]] || die "Missing ${env_file}. Copy config/prep.env.example and edit it."
  # Deliberately NOT `set -a`. oc-mirror embeds docker/distribution for its
  # local storage, and that claims the whole REGISTRY_* environment namespace
  # as its own configuration. Exporting REGISTRY_HOST/REGISTRY_PORT makes
  # every run log:
  #   warning msg="Ignoring unrecognized environment variable REGISTRY_HOST"
  # and a name that *is* recognised (REGISTRY_STORAGE_*, REGISTRY_HTTP_*)
  # would silently reconfigure oc-mirror's internal registry.
  # Every value here is passed to tools as an explicit flag, so shell-local
  # scope is sufficient.
  # shellcheck disable=SC1090
  source "${env_file}"
  # OCP_AIRGAP_ROOT resolves from the environment first (prep.env uses :-),
  # so an exported value from /etc/profile.d wins over the file's default.
  # Print what it resolved to: two sources, one path, and the transcript
  # should say which one won.
  info "OCP_AIRGAP_ROOT: ${OCP_AIRGAP_ROOT:-<unset>}"
}

require_vars() {
  local missing=()
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("${v}")
  done
  (( ${#missing[@]} == 0 )) || die "Unset in config/prep.env: ${missing[*]}"
}

require_cmds() {
  local missing=()
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  (( ${#missing[@]} == 0 )) || die "Not on PATH: ${missing[*]}"
}

# --- assertions ------------------------------------------------------------

# require_space <path> <gb>
require_space() {
  local path="$1" need_gb="$2" avail_gb
  # Walk up to the nearest existing ancestor so this works before mkdir.
  while [[ ! -d "${path}" && "${path}" != "/" ]]; do path="$(dirname "${path}")"; done
  avail_gb=$(df -BG --output=avail "${path}" 2>/dev/null | tail -1 | tr -dc '0-9')
  [[ -n "${avail_gb}" ]] || { warn "Could not determine free space on ${path}"; return 0; }
  if (( avail_gb < need_gb )); then
    die "${path} has ${avail_gb} GB free, need at least ${need_gb} GB."
  fi
  ok "${path}: ${avail_gb} GB free (need ${need_gb} GB)"
}

# mount_point <path> -- the filesystem a path lives on, or "" if unknowable.
# Walks up to the nearest existing ancestor, so it works before the prep tree
# has been created. Never fails: callers run under `set -e` with pipefail,
# where a bare `df` on a missing path would abort the script.
mount_point() {
  local path="$1"
  while [[ ! -d "${path}" && "${path}" != "/" && "${path}" != "." ]]; do
    path="$(dirname "${path}")"
  done
  df -P "${path}" 2>/dev/null | tail -1 | awk '{print $NF}' || true
}

registry_ref() { printf '%s:%s' "${REGISTRY_HOST}" "${REGISTRY_PORT}"; }

# oc-mirror requires umask 0022 and emits
#   "Detected bad umask 0077 (oc-mirror requires a umask of 0022)"
# on every invocation otherwise. STIG sets 0077, so every script that runs
# oc-mirror must relax it. Verified against oc-mirror 4.21 on RHEL 9.6.
use_oc_mirror_umask() {
  local cur; cur="$(umask)"
  if [[ "${cur}" != "0022" ]]; then
    info "umask is ${cur}; oc-mirror requires 0022. Setting it for this script."
    umask 0022
  fi
}

# oc-mirror stages temporary image blobs in TMPDIR and unpacks a helper
# binary it then executes. The default is /var/tmp, which STIG requires to be
# a separate 5 GB file system -- see docs/appendix-fips-stig.md.
#
# This is one of the few settings that cannot be passed as a flag, so unlike
# the rest of prep.env it has to be exported.
use_mirror_tmpdir() {
  [[ -n "${MIRROR_TMPDIR:-}" ]] || return 0
  mkdir -p "${MIRROR_TMPDIR}" || die "Cannot create MIRROR_TMPDIR=${MIRROR_TMPDIR}"
  export TMPDIR="${MIRROR_TMPDIR}"
  info "TMPDIR=${TMPDIR}  <- temporary image blobs land here"

  # A noexec mount or a fapolicyd denial turns the space fix into an exec
  # failure hours later. Probe now, while it is cheap to diagnose.
  local probe="${TMPDIR}/.exec-probe.$$"
  printf '#!/bin/sh\nexit 0\n' > "${probe}" 2>/dev/null || return 0
  chmod 0700 "${probe}" 2>/dev/null || true
  "${probe}" 2>/dev/null \
    || warn "${TMPDIR} will not execute a test binary (noexec mount, or fapolicyd). oc-mirror will fail on exec."
  rm -f "${probe}"
}

# Assert a binary actually executes. On a fapolicyd host a freshly installed
# binary can be denied, and the trust database update is not instantaneous --
# so retry briefly before giving up.
assert_executes() {
  local bin="$1" tries="${2:-5}" out
  for ((i=1; i<=tries; i++)); do
    if out="$("${bin}" version --client 2>&1)" || [[ -n "${out}" ]]; then
      if [[ -n "${out}" ]] && ! grep -qi 'operation not permitted\|permission denied' <<<"${out}"; then
        printf '%s\n' "${out}" | head -1
        return 0
      fi
    fi
    sleep 2
  done
  die "${bin} does not execute. On a fapolicyd host see docs/appendix-fips-stig.md."
}

# Blocking confirmation, for genuinely destructive choices only.
# Never silently consumes EOF: under nohup/CI stdin is closed, and a bare
# `read` there yields an empty answer that looks like a deliberate refusal.
confirm() {
  local prompt="${1:-Continue?}"
  [[ "${ASSUME_YES:-false}" == "true" ]] && return 0
  if [[ ! -t 0 ]]; then
    die "Confirmation needed but stdin is not a terminal: ${prompt}
Re-run interactively, or set ASSUME_YES=true to accept this automatically."
  fi
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]] || die "Aborted by user."
}

# Advisory check: long runs should be inside tmux so a dropped SSH session
# does not kill them. Advice, not a gate -- it must never block automation.
advise_tmux() {
  [[ -n "${TMUX:-}" ]] && return 0
  command -v tmux >/dev/null 2>&1 || return 0
  warn "Not inside tmux. This runs for a long time; a dropped SSH session kills it."
  warn "  sudo loginctl enable-linger \$USER"
  warn "  systemd-run --scope --user tmux new -s mirror"
  if [[ -t 0 && "${ASSUME_YES:-false}" != "true" ]]; then
    confirm "Continue anyway?"
  else
    warn "  (non-interactive -- continuing)"
  fi
}
