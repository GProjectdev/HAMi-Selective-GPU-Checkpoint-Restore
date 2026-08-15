#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/kubernetes.sh"

parse_common_args "$@"
load_env
init_result_dir deploy-workloads
require_kubectl
require_cmd envsubst
confirm_destructive "Deploying test namespace and pods"

export WORKLOAD_BASE_IMAGE POD_A_MEMORY_MB POD_A_CORE_PERCENT POD_B_MEMORY_MB POD_B_CORE_PERCENT
WORKLOAD_BASE_IMAGE="${WORKLOAD_BASE_IMAGE:-nvidia/cuda:12.4.1-devel-ubuntu22.04}"

kubectl_apply "${REPO_ROOT}/manifests/namespace.yaml"
kubectl_apply "${REPO_ROOT}/manifests/rbac.yaml"
if [[ "${DRY_RUN}" == "true" ]]; then
  kubectl -n "${EXPERIMENT_NAMESPACE}" create configmap hami-pod-a-source \
    --from-file=main.cu="${REPO_ROOT}/workloads/selective-target/src/main.cu" \
    --dry-run=client -o yaml | kubectl apply --dry-run=server -f -
  kubectl -n "${EXPERIMENT_NAMESPACE}" create configmap hami-pod-b-source \
    --from-file=main.cu="${REPO_ROOT}/workloads/co-runner/src/main.cu" \
    --dry-run=client -o yaml | kubectl apply --dry-run=server -f -
else
  kubectl -n "${EXPERIMENT_NAMESPACE}" create configmap hami-pod-a-source \
    --from-file=main.cu="${REPO_ROOT}/workloads/selective-target/src/main.cu" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${EXPERIMENT_NAMESPACE}" create configmap hami-pod-b-source \
    --from-file=main.cu="${REPO_ROOT}/workloads/co-runner/src/main.cu" \
    --dry-run=client -o yaml | kubectl apply -f -
fi
if [[ "${DRY_RUN}" != "true" ]]; then
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod hami-pod-a hami-pod-b --ignore-not-found=true --wait=true
fi
if [[ "${DRY_RUN}" == "true" ]]; then
  envsubst < "${REPO_ROOT}/manifests/pod-a.yaml" | kubectl apply --dry-run=server -f -
  envsubst < "${REPO_ROOT}/manifests/pod-b.yaml" | kubectl apply --dry-run=server -f -
else
  envsubst < "${REPO_ROOT}/manifests/pod-a.yaml" | kubectl apply -f -
  envsubst < "${REPO_ROOT}/manifests/pod-b.yaml" | kubectl apply -f -
fi
if [[ "${DRY_RUN}" != "true" ]]; then
  kubectl -n "${EXPERIMENT_NAMESPACE}" get pod hami-pod-a hami-pod-b \
    -o custom-columns=NAME:.metadata.name,SCHEDULER:.spec.schedulerName,PHASE:.status.phase,NODE:.spec.nodeName
  wait_pod_ready hami-pod-a
  wait_pod_ready hami-pod-b
fi
