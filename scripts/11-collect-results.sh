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
capture gpucheckpoint kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint -o yaml
capture gpurestore kubectl -n "${EXPERIMENT_NAMESPACE}" get gpurestore -o yaml
capture pod-a-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-a --tail=500
capture restored-pod-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-a-restored --tail=500
capture pod-b-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=500
capture kube-system-hami kubectl -n kube-system get pods -o wide
capture gpu-cr-system kubectl -n "${GPU_CR_NAMESPACE:-gpu-cr-system}" get pods -o wide
log "Result collection complete."
