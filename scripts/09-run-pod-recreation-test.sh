#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir pod-recreation
require_kubectl
require_cmd envsubst
confirm_destructive "Deleting Pod A and applying WorkloadRestore"

run_cmd kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod hami-pod-a --ignore-not-found=true
if [[ "${DRY_RUN}" == "true" ]]; then
  envsubst < "${REPO_ROOT}/manifests/checkpoint-resources.yaml" | kubectl apply --dry-run=server -f -
else
  envsubst < "${REPO_ROOT}/manifests/checkpoint-resources.yaml" | kubectl apply -f -
fi
capture restore-objects kubectl -n "${EXPERIMENT_NAMESPACE}" get workloadrestore -o yaml
capture pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -o wide
