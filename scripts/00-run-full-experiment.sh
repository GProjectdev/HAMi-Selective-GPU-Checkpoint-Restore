#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
RUN_ROOT="${REPO_ROOT}/results/${RUN_ID}-full-experiment"
STATE_ROOT="${REPO_ROOT}/.state"
YES=false
FROM_STAGE=""
NO_CRD=false
LIST=false

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/00-run-full-experiment.sh --yes [--no-crd] [--from STAGE] [--list]

Run the default same-worker HAMi selective GPU checkpoint/restore experiment.

Options:
  --yes         required; allows mutating stages to call their own --yes paths
  --no-crd      run the no-CRD selective isolation probe instead of real GPU C/R
  --from STAGE resume from a stage id, for example deploy-workloads
  --list        print stage ids and exit

Failure evidence:
  results/<timestamp>-full-experiment/<NN-stage>.log
  results/<timestamp>-full-experiment/summary.md
  .state/full-experiment-current-stage
  .state/full-experiment-last-failed-stage
  .state/full-experiment-last-run-dir
EOF
}

STAGES=(
  "01-generate-env|Generate config/experiment.env|./scripts/00-generate-experiment-env.sh --force"
  "02-preflight|Check kube-context, nodes, and GPU visibility|./scripts/00-preflight.sh"
  "03-backup|Backup current cluster environment|./scripts/01-backup-current-environment.sh"
  "04-install-hami|Install or upgrade HAMi|./scripts/02-install-hami.sh --yes"
  "05-verify-hami|Verify HAMi components|./scripts/03-verify-hami.sh"
  "06-install-gpu-cr-checkpoint|Install GPUCheckpoint CRD and Node Agent|./scripts/04-install-gpu-cr-checkpoint-system.sh --yes"
  "07-check-restore-runtime|Record restore runtime prerequisites|./scripts/04-check-gpu-cr-restore-runtime.sh"
  "08-deploy-workloads|Deploy Pod A and Pod B on the same-worker experiment path|./scripts/05-deploy-test-workloads.sh --yes"
  "09-baseline|Collect baseline logs and GPU state|./scripts/06-run-baseline-test.sh"
  "10-checkpoint-pod-a|Checkpoint only Pod A|./scripts/08-run-gcr-criu-selective-test.sh --yes"
  "11-restore-pod-a|Restore Pod A after Pod recreation|./scripts/09-run-pod-recreation-test.sh --yes"
  "12-collect-results|Collect final experiment results|./scripts/11-collect-results.sh"
)

stage_id() { printf '%s' "$1" | cut -d'|' -f1; }
stage_desc() { printf '%s' "$1" | cut -d'|' -f2; }
stage_cmd() { printf '%s' "$1" | cut -d'|' -f3-; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=true ;;
    --no-crd) NO_CRD=true ;;
    --from) shift; FROM_STAGE="${1:?missing stage id}" ;;
    --list) LIST=true ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

if [[ "${NO_CRD}" == "true" ]]; then
  STAGES=(
    "01-generate-env|Generate config/experiment.env|./scripts/00-generate-experiment-env.sh --force"
    "02-preflight|Check kube-context, nodes, and GPU visibility|./scripts/00-preflight.sh"
    "03-backup|Backup current cluster environment|./scripts/01-backup-current-environment.sh"
    "04-install-hami|Install or upgrade HAMi|./scripts/02-install-hami.sh --yes"
    "05-verify-hami|Verify HAMi components|./scripts/03-verify-hami.sh"
    "06-deploy-workloads|Deploy Pod A and Pod B on the same-worker experiment path|./scripts/05-deploy-test-workloads.sh --yes"
    "07-baseline|Collect baseline logs and GPU state|./scripts/06-run-baseline-test.sh"
    "08-no-crd-isolation|Delete and recreate Pod A while checking Pod B continuity|./scripts/08-run-no-crd-selective-isolation-test.sh --yes"
    "09-collect-results|Collect final experiment results|./scripts/11-collect-results.sh"
  )
fi

if [[ "${LIST}" == "true" ]]; then
  for stage in "${STAGES[@]}"; do
    printf '%s\t%s\n' "$(stage_id "${stage}")" "$(stage_desc "${stage}")"
  done
  exit 0
fi

[[ "${YES}" == "true" ]] || die "Full experiment includes cluster-mutating stages. Re-run with --yes."

mkdir -p "${RUN_ROOT}" "${STATE_ROOT}"
printf '%s\n' "${RUN_ROOT}" > "${STATE_ROOT}/full-experiment-last-run-dir"
rm -f "${STATE_ROOT}/full-experiment-completed-stages" "${STATE_ROOT}/full-experiment-last-failed-stage"

summary="${RUN_ROOT}/summary.md"
cat > "${summary}" <<EOF
# Full Experiment Run

- run id: ${RUN_ID}
- repository: ${REPO_ROOT}
- mode: $([[ "${NO_CRD}" == "true" ]] && printf 'no-crd-selective-isolation' || printf 'checkpoint-restore')
- started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

EOF

start_seen=false
if [[ -z "${FROM_STAGE}" ]]; then
  start_seen=true
fi

for index in "${!STAGES[@]}"; do
  stage="${STAGES[$index]}"
  id="$(stage_id "${stage}")"
  desc="$(stage_desc "${stage}")"
  cmd="$(stage_cmd "${stage}")"

  if [[ "${start_seen}" != "true" ]]; then
    [[ "${id}" == "${FROM_STAGE}" ]] && start_seen=true || continue
  fi

  number="$(printf '%02d' "$((index + 1))")"
  logfile="${RUN_ROOT}/${number}-${id}.log"
  printf '%s\n' "${id}" > "${STATE_ROOT}/full-experiment-current-stage"

  log "START ${id}: ${desc}"
  set +e
  {
    printf '[stage] %s\n[description] %s\n[command] %s\n[started] %s\n\n' \
      "${id}" "${desc}" "${cmd}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    bash -lc "cd '${REPO_ROOT}' && ${cmd}"
  } >"${logfile}" 2>&1
  code=$?
  set -e

  if [[ ${code} -ne 0 ]]; then
    printf '%s\n' "${id}" > "${STATE_ROOT}/full-experiment-last-failed-stage"
    {
      printf '\n## FAILED: %s\n\n' "${id}"
      printf -- '- description: %s\n' "${desc}"
      printf -- '- exit code: %s\n' "${code}"
      printf -- '- log: %s\n' "${logfile}"
      printf -- '- stopped at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >> "${summary}"
    log "FAILED ${id} with exit code ${code}"
    log "Stopped at stage: ${id}"
    log "Read log: ${logfile}"
    log "Resume after fixing with: ./scripts/00-run-full-experiment.sh --yes --from ${id}"
    exit "${code}"
  fi

  printf '%s\n' "${id}" >> "${STATE_ROOT}/full-experiment-completed-stages"
  printf -- '- OK `%s`: %s\n' "${id}" "${desc}" >> "${summary}"
  log "OK ${id}"
done

rm -f "${STATE_ROOT}/full-experiment-current-stage" "${STATE_ROOT}/full-experiment-last-failed-stage"
{
  printf '\n## COMPLETE\n\n'
  printf -- '- finished: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf -- '- run dir: %s\n' "${RUN_ROOT}"
} >> "${summary}"
log "Full experiment complete."
log "Summary: ${summary}"
