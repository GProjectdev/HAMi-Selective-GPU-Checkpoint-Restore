#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir install-gpu-cr-checkpoint
require_kubectl
confirm_destructive "Installing GPUCheckpoint CRD, RBAC, and Node Agent"

BASE_CR_REPO="${BASE_CR_REPO:-../K8s-Native-Fast-GPU-Checkpoint-Restore-System}"
base_path="${REPO_ROOT}/${BASE_CR_REPO}"
[[ -d "${base_path}" ]] || die "Checkpoint repository not found: ${base_path}"

crd="${base_path}/config/crd/gpu-cr.io_gpucheckpoints.yaml"
rbac="${base_path}/deploy/rbac.yaml"
daemonset="${base_path}/deploy/daemonset-crio.yaml"
[[ -f "${crd}" ]] || die "Missing GPUCheckpoint CRD: ${crd}"
[[ -f "${rbac}" ]] || die "Missing checkpoint RBAC: ${rbac}"
[[ -f "${daemonset}" ]] || die "Missing checkpoint Node Agent DaemonSet: ${daemonset}"

if [[ "${DRY_RUN}" == "true" ]]; then
  run_cmd kubectl apply --dry-run=server -f "${crd}"
  run_cmd kubectl apply --dry-run=server -f "${rbac}"
  run_cmd kubectl apply --dry-run=server -f "${daemonset}"
  exit 0
fi

kubectl apply -f "${crd}"
kubectl apply -f "${rbac}"

mapfile -t gpu_nodes < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk '$2 != "" && $2 != "0" {print $1}')
for node in "${gpu_nodes[@]}"; do
  kubectl label node "${node}" nvidia.com/gpu.present=true --overwrite
done

kubectl apply -f "${daemonset}"
kubectl -n "${GPU_CR_NAMESPACE:-gpu-cr-system}" rollout status ds/gpu-cr-node-agent --timeout="${RESTORE_TIMEOUT_SECONDS:-300}s"

capture gpu-cr-crds kubectl get crd gpucheckpoints.gpu-cr.io -o yaml
capture gpu-cr-node-agent kubectl -n "${GPU_CR_NAMESPACE:-gpu-cr-system}" get pods -o wide
append_summary "# GPU C/R Checkpoint System" "" "- GPUCheckpoint CRD applied." "- gpu-cr-node-agent DaemonSet rolled out." "- GPU nodes labelled nvidia.com/gpu.present=true."
