#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/kubernetes.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir no-crd-selective-isolation
require_kubectl
require_cmd envsubst
confirm_destructive "Running no-CRD selective isolation probe by recreating Pod A"

WORKLOAD_BASE_IMAGE="${WORKLOAD_BASE_IMAGE:-nvidia/cuda:12.4.1-devel-ubuntu22.04}"
export WORKLOAD_BASE_IMAGE POD_A_MEMORY_MB POD_A_CORE_PERCENT POD_B_MEMORY_MB POD_B_CORE_PERCENT

capture pods-before kubectl -n "${EXPERIMENT_NAMESPACE}" get pod hami-pod-a hami-pod-b -o wide
capture pod-b-before kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=200
capture pod-b-describe-before kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod hami-pod-b

run_cmd kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod hami-pod-a --ignore-not-found=true --wait=true

if [[ "${DRY_RUN}" == "true" ]]; then
  kubectl -n "${EXPERIMENT_NAMESPACE}" create configmap hami-pod-a-source \
    --from-file=main.cu="${REPO_ROOT}/workloads/selective-target/src/main.cu" \
    --dry-run=client -o yaml | kubectl apply --dry-run=server -f -
  envsubst < "${REPO_ROOT}/manifests/pod-a.yaml" | kubectl apply --dry-run=server -f -
else
  kubectl -n "${EXPERIMENT_NAMESPACE}" create configmap hami-pod-a-source \
    --from-file=main.cu="${REPO_ROOT}/workloads/selective-target/src/main.cu" \
    --dry-run=client -o yaml | kubectl apply -f -
  envsubst < "${REPO_ROOT}/manifests/pod-a.yaml" | kubectl apply -f -
  wait_pod_ready hami-pod-a
fi

sleep 10
capture pods-after kubectl -n "${EXPERIMENT_NAMESPACE}" get pod hami-pod-a hami-pod-b -o wide
capture pod-a-after kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-a --tail=200
capture pod-b-after kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=200
capture pod-b-describe-after kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod hami-pod-b
capture events kubectl -n "${EXPERIMENT_NAMESPACE}" get events --sort-by=.lastTimestamp

append_summary "# No-CRD selective isolation probe" \
  "" \
  "- This is not a GPU checkpoint/restore proof." \
  "- Pod A was deleted and recreated on the HAMi path." \
  "- Pod B before/after logs and pod descriptions were captured to check whether it continued running."

