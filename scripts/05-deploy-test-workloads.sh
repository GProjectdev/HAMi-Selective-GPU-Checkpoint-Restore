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

export TARGET_IMAGE CO_RUNNER_IMAGE POD_A_MEMORY_MB POD_A_CORE_PERCENT POD_B_MEMORY_MB POD_B_CORE_PERCENT
[[ -n "${TARGET_IMAGE:-}" ]] || die "Set TARGET_IMAGE."
[[ -n "${CO_RUNNER_IMAGE:-}" ]] || die "Set CO_RUNNER_IMAGE."

kubectl_apply "${REPO_ROOT}/manifests/namespace.yaml"
kubectl_apply "${REPO_ROOT}/manifests/rbac.yaml"
if [[ "${DRY_RUN}" == "true" ]]; then
  envsubst < "${REPO_ROOT}/manifests/pod-a.yaml" | kubectl apply --dry-run=server -f -
  envsubst < "${REPO_ROOT}/manifests/pod-b.yaml" | kubectl apply --dry-run=server -f -
else
  envsubst < "${REPO_ROOT}/manifests/pod-a.yaml" | kubectl apply -f -
  envsubst < "${REPO_ROOT}/manifests/pod-b.yaml" | kubectl apply -f -
fi
if [[ "${DRY_RUN}" != "true" ]]; then
  wait_pod_ready hami-pod-a
  wait_pod_ready hami-pod-b
fi
