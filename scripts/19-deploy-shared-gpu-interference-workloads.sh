#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/kubernetes.sh"
source "${REPO_ROOT}/lib/result.sh"

MODEL="gpt2"
NODE=""
POD_COUNT=3
GROUP="shared-gpu-interference"
GPU_MEMORY_MB=""
GPU_CORE_PERCENT=""
WORKLOAD_KIND="model"
SYNTHETIC_ALLOC_MB="2048"
SYNTHETIC_OP_SIZE="4096"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) shift; MODEL="${1:?missing model}" ;;
    --node) shift; NODE="${1:?missing node}" ;;
    --pod-count) shift; POD_COUNT="${1:?missing pod count}" ;;
    --group) shift; GROUP="${1:?missing group}" ;;
    --gpu-memory-mb) shift; GPU_MEMORY_MB="${1:?missing gpu memory mb}" ;;
    --gpu-core-percent) shift; GPU_CORE_PERCENT="${1:?missing gpu core percent}" ;;
    --workload-kind) shift; WORKLOAD_KIND="${1:?missing workload kind}" ;;
    --synthetic-alloc-mb) shift; SYNTHETIC_ALLOC_MB="${1:?missing synthetic alloc mb}" ;;
    --synthetic-op-size) shift; SYNTHETIC_OP_SIZE="${1:?missing synthetic op size}" ;;
    --dry-run|--yes|-y|--env-file)
      break
      ;;
    *) die "Unknown argument before common args: $1" ;;
  esac
  shift
done

parse_common_args "$@"
load_env
init_result_dir "deploy-shared-gpu-interference-${MODEL//[^A-Za-z0-9._-]/-}"
require_kubectl
require_cmd envsubst
confirm_destructive "Deploying shared-GPU checkpoint interference workloads"

case "${MODEL}" in
  gpt2)
    INFERENCE_MODEL_ID="${GPT2_MODEL_ID:-gpt2}"
    INFERENCE_MODEL_RELATIVE_PATH="${GPT2_MODEL_RELATIVE_PATH:-gpt2}"
    DEFAULT_GPU_MEMORY_MB="${GPT2_INTERFERENCE_GPU_MEMORY_MB:-8192}"
    DEFAULT_GPU_CORE_PERCENT="${GPT2_INTERFERENCE_GPU_CORE_PERCENT:-30}"
    ;;
  opt-1.3b|facebook/opt-1.3b)
    INFERENCE_MODEL_ID="${OPT13B_MODEL_ID:-facebook/opt-1.3b}"
    INFERENCE_MODEL_RELATIVE_PATH="${OPT13B_MODEL_RELATIVE_PATH:-facebook/opt-1.3b}"
    DEFAULT_GPU_MEMORY_MB="${OPT13B_INTERFERENCE_GPU_MEMORY_MB:-12288}"
    DEFAULT_GPU_CORE_PERCENT="${OPT13B_INTERFERENCE_GPU_CORE_PERCENT:-30}"
    ;;
  *)
    die "Unsupported model: ${MODEL}. Use gpt2 or opt-1.3b."
    ;;
esac

if [[ -z "${NODE}" ]]; then
  NODE="${TARGET_NODE:-}"
fi
[[ -n "${NODE}" ]] || die "Set --node or TARGET_NODE. This experiment must pin all Pods to one HAMi GPU worker."

[[ "${POD_COUNT}" =~ ^[0-9]+$ ]] || die "--pod-count must be numeric."
(( POD_COUNT >= 2 && POD_COUNT <= 6 )) || die "--pod-count must be between 2 and 6."
case "${WORKLOAD_KIND}" in
  model|synthetic) ;;
  *) die "--workload-kind must be model or synthetic." ;;
esac

INTERFERENCE_MODEL_SAFE_NAME="$(tr '/:.' '---' <<<"${MODEL}" | tr -cd 'A-Za-z0-9-')"
INTERFERENCE_GROUP="${GROUP}"
INTERFERENCE_NODE="${NODE}"
INTERFERENCE_WORKLOAD_KIND="${WORKLOAD_KIND}"
INTERFERENCE_GPU_MEMORY_MB="${GPU_MEMORY_MB:-${DEFAULT_GPU_MEMORY_MB}}"
INTERFERENCE_GPU_CORE_PERCENT="${GPU_CORE_PERCENT:-${DEFAULT_GPU_CORE_PERCENT}}"
INFERENCE_IMAGE="${INFERENCE_IMAGE:-pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime}"
INFERENCE_PIP_INSTALL="${INFERENCE_PIP_INSTALL:-true}"
INFERENCE_PIP_PACKAGES="${INFERENCE_PIP_PACKAGES:-transformers==4.44.2 accelerate==0.34.2 sentencepiece protobuf}"
INFERENCE_MAX_NEW_TOKENS="${INFERENCE_MAX_NEW_TOKENS:-24}"
INFERENCE_SLEEP_SECONDS="${INFERENCE_SLEEP_SECONDS:-0.2}"
MODEL_NFS_SERVER="${MODEL_NFS_SERVER:-${NFS_SERVER:-10.178.0.14}}"
MODEL_NFS_EXPORT_PATH="${MODEL_NFS_EXPORT_PATH:-${NFS_EXPORT_PATH:-/mnt/nfs}}"
GCR_REMOTE_SINK="${GCR_REMOTE_SINK:-}"
GCR_REMOTE_HOST="${GCR_REMOTE_HOST:-}"
GCR_REMOTE_PORT="${GCR_REMOTE_PORT:-19092}"
GCR_REMOTE_REQUIRED="${GCR_REMOTE_REQUIRED:-false}"

[[ -n "${GPU_CR_LIB_HOST_PATH:-}" ]] || die "Set GPU_CR_LIB_HOST_PATH."
[[ -n "${GCR_CONTROL_DIR:-}" ]] || die "Set GCR_CONTROL_DIR."
[[ -n "${GCR_DATA_DIR:-}" ]] || die "Set GCR_DATA_DIR."
[[ -n "${CHECKPOINT_STORAGE_PATH:-}" ]] || die "Set CHECKPOINT_STORAGE_PATH."

export EXPERIMENT_NAMESPACE INTERFERENCE_GROUP INTERFERENCE_MODEL_SAFE_NAME INTERFERENCE_NODE
export INTERFERENCE_WORKLOAD_KIND SYNTHETIC_ALLOC_MB SYNTHETIC_OP_SIZE
export INFERENCE_MODEL_ID INFERENCE_MODEL_RELATIVE_PATH INFERENCE_IMAGE INFERENCE_PIP_INSTALL
export INFERENCE_PIP_PACKAGES INFERENCE_MAX_NEW_TOKENS INFERENCE_SLEEP_SECONDS
export INTERFERENCE_GPU_MEMORY_MB INTERFERENCE_GPU_CORE_PERCENT
export MODEL_NFS_SERVER MODEL_NFS_EXPORT_PATH GPU_CR_LIB_HOST_PATH GCR_CONTROL_DIR GCR_DATA_DIR CHECKPOINT_STORAGE_PATH
export GCR_REMOTE_SINK GCR_REMOTE_HOST GCR_REMOTE_PORT GCR_REMOTE_REQUIRED

kubectl_apply "${REPO_ROOT}/manifests/namespace.yaml"
kubectl_apply "${REPO_ROOT}/manifests/rbac.yaml"

letters=(a b c d e f)
deployed=()
if [[ "${DRY_RUN}" != "true" ]]; then
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod -l "experiment.gpu-cr/group=${GROUP}" --ignore-not-found=true --wait=true
fi

for idx in $(seq 0 $((POD_COUNT - 1))); do
  INTERFERENCE_WORKER="${letters[$idx]}"
  INTERFERENCE_POD_NAME="hami-interf-${INTERFERENCE_MODEL_SAFE_NAME}-${INTERFERENCE_WORKER}"
  export INTERFERENCE_WORKER INTERFERENCE_POD_NAME
  deployed+=("${INTERFERENCE_POD_NAME}")

  rendered="${RESULT_DIR}/${INTERFERENCE_POD_NAME}.yaml"
  envsubst < "${REPO_ROOT}/manifests/shared-gpu-interference-pod.yaml" > "${rendered}"
  grep -q "experiment.gpu-cr/group: ${GROUP}$" "${rendered}" || die "Rendered manifest is missing the expected group label: ${GROUP}"
  grep -q "kubernetes.io/hostname: ${NODE}$" "${rendered}" || die "Rendered manifest is missing the expected node selector: ${NODE}"
  grep -q "value: ${WORKLOAD_KIND}$" "${rendered}" || die "Rendered manifest is missing the expected workload kind: ${WORKLOAD_KIND}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    kubectl apply --dry-run=server -f "${rendered}"
  else
    kubectl apply -f "${rendered}"
  fi
done

if [[ "${DRY_RUN}" != "true" ]]; then
  for pod in "${deployed[@]}"; do
    kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready "pod/${pod}" --timeout="${INFERENCE_READY_TIMEOUT_SECONDS:-900}s"
  done

  capture pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -l "experiment.gpu-cr/group=${GROUP}" -o wide
  capture pod-yaml kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -l "experiment.gpu-cr/group=${GROUP}" -o yaml
  for pod in "${deployed[@]}"; do
    capture "logs-${pod}" kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${pod}" --tail=120
  done

  printf '%s\n' "${deployed[@]}" > "${RESULT_DIR}/pods.txt"
  write_state "last-shared-gpu-interference-group" "${GROUP}"
  write_state "last-shared-gpu-interference-node" "${NODE}"
  write_state "last-shared-gpu-interference-model" "${MODEL}"
  write_state "last-shared-gpu-interference-workload-kind" "${WORKLOAD_KIND}"
  write_state "last-shared-gpu-interference-pod-count" "${POD_COUNT}"
  write_state "last-shared-gpu-interference-pods" "$(IFS=,; echo "${deployed[*]}")"

  append_summary "# Shared GPU Interference Workloads" "" \
    "- model: ${MODEL}" \
    "- node: ${NODE}" \
    "- pod-count: ${POD_COUNT}" \
    "- workload-kind: ${WORKLOAD_KIND}" \
    "- synthetic-alloc-mb: ${SYNTHETIC_ALLOC_MB}" \
    "- synthetic-op-size: ${SYNTHETIC_OP_SIZE}" \
    "- gpu-memory-mb-per-pod: ${INTERFERENCE_GPU_MEMORY_MB}" \
    "- gpu-core-percent-per-pod: ${INTERFERENCE_GPU_CORE_PERCENT}" \
    "- pods: $(IFS=', '; echo "${deployed[*]}")"
fi
