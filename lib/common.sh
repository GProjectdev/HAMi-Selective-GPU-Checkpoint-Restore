#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/config/experiment.env}"
DRY_RUN=false
YES=false
RESULT_DIR=""

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

on_error() {
  local code=$?
  log "Failed at line ${BASH_LINENO[0]} with exit code ${code}."
  log "Recovery: inspect the latest result directory, then run scripts/99-rollback-to-original-environment.sh --yes if cluster state must be restored."
  exit "${code}"
}
trap on_error ERR

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --yes|-y) YES=true ;;
      --env-file) shift; ENV_FILE="${1:?missing env file}" ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
}

load_env() {
  [[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}. Copy config/experiment.env.example first."
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  EXPERIMENT_NAMESPACE="${EXPERIMENT_NAMESPACE:-hami-selective-cr}"
  RESULT_ROOT="${RESULT_ROOT:-./results}"
  BACKUP_ROOT="${BACKUP_ROOT:-./backups}"
  STATE_ROOT="${STATE_ROOT:-./.state}"
}

init_result_dir() {
  local name="${1:-run}"
  local ts
  ts="$(date -u '+%Y%m%dT%H%M%SZ')"
  RESULT_DIR="${REPO_ROOT}/${RESULT_ROOT#./}/${ts}-${name}"
  mkdir -p "${RESULT_DIR}"
  log "Result directory: ${RESULT_DIR}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_kubectl() {
  require_cmd kubectl
  log "Current kube-context: $(kubectl config current-context 2>/dev/null || echo UNKNOWN)"
  kubectl cluster-info >/dev/null
}

confirm_destructive() {
  local message="$1"
  if [[ "${YES}" == "true" ]]; then
    log "${message}"
    return
  fi
  die "${message} requires --yes."
}

run_cmd() {
  log "+ $*"
  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi
  "$@"
}

write_state() {
  mkdir -p "${REPO_ROOT}/${STATE_ROOT#./}"
  printf '%s\n' "$2" > "${REPO_ROOT}/${STATE_ROOT#./}/$1"
}

assert_not_home_git_root() {
  local top
  top="$(git -C "${REPO_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)"
  log "Repository root: ${top:-UNKNOWN}"
}

