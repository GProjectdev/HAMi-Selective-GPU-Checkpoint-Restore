#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir collect
require_kubectl

capture pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -o wide
capture events kubectl -n "${EXPERIMENT_NAMESPACE}" get events --sort-by=.lastTimestamp
capture workload-crs kubectl -n "${EXPERIMENT_NAMESPACE}" get workloadcheckpoint,workloadrestore -o yaml
capture pod-a-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-a --tail=500
capture pod-b-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=500
capture kube-system-hami kubectl -n kube-system get pods -o wide
log "Result collection complete."

