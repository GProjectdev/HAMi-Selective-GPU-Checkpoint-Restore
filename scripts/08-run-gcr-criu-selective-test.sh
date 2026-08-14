#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir selective-gcr-criu
require_kubectl
require_cmd envsubst
confirm_destructive "Creating WorkloadCheckpoint for Pod A"

[[ -n "${SHARED_CHECKPOINT_ROOT:-}" ]] || die "Set SHARED_CHECKPOINT_ROOT."
if [[ "${DRY_RUN}" == "true" ]]; then
  envsubst < "${REPO_ROOT}/manifests/checkpoint-resources.yaml" | kubectl apply --dry-run=server -f -
else
  envsubst < "${REPO_ROOT}/manifests/checkpoint-resources.yaml" | kubectl apply -f -
fi
capture pod-b-before kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=100
capture checkpoint-objects kubectl -n "${EXPERIMENT_NAMESPACE}" get workloadcheckpoint,workloadrestore -o yaml
capture pod-b-after kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=100
append_summary "# Selective C/R" "" "- Pod A checkpoint object submitted." "- Pod B before/after logs captured."
