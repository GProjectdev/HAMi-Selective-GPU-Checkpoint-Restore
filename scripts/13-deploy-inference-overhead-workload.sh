#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/kubernetes.sh"
source "${REPO_ROOT}/lib/result.sh"

MODEL="gpt2"
NODE=""
POD_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) shift; MODEL="${1:?missing model}" ;;
    --node) shift; NODE="${1:?missing node}" ;;
    --pod-name) shift; POD_NAME="${1:?missing pod name}" ;;
    --dry-run|--yes|-y|--env-file)
      break
      ;;
    *) die "Unknown argument before common args: $1" ;;
  esac
  shift
done

parse_common_args "$@"
load_env
init_result_dir "deploy-inference-${MODEL//[^A-Za-z0-9._-]/-}"
require_kubectl
require_cmd envsubst
confirm_destructive "Deploying inference checkpoint-overhead workload"

case "${MODEL}" in
  gpt2)
    INFERENCE_MODEL_ID="${GPT2_MODEL_ID:-gpt2}"
    INFERENCE_MODEL_RELATIVE_PATH="${GPT2_MODEL_RELATIVE_PATH:-gpt2}"
    INFERENCE_GPU_MEMORY_MB="${GPT2_GPU_MEMORY_MB:-8192}"
    INFERENCE_GPU_CORE_PERCENT="${GPT2_GPU_CORE_PERCENT:-40}"
    ;;
  opt-1.3b|facebook/opt-1.3b)
    INFERENCE_MODEL_ID="${OPT13B_MODEL_ID:-facebook/opt-1.3b}"
    INFERENCE_MODEL_RELATIVE_PATH="${OPT13B_MODEL_RELATIVE_PATH:-facebook/opt-1.3b}"
    INFERENCE_GPU_MEMORY_MB="${OPT13B_GPU_MEMORY_MB:-24576}"
    INFERENCE_GPU_CORE_PERCENT="${OPT13B_GPU_CORE_PERCENT:-70}"
    ;;
  *)
    die "Unsupported model: ${MODEL}. Use gpt2 or opt-1.3b."
    ;;
esac

INFERENCE_MODEL_SAFE_NAME="$(tr '/:.' '---' <<<"${MODEL}" | tr -cd 'A-Za-z0-9-')"
INFERENCE_POD_NAME="${POD_NAME:-hami-infer-${INFERENCE_MODEL_SAFE_NAME}}"
INFERENCE_IMAGE="${INFERENCE_IMAGE:-pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime}"
INFERENCE_PIP_INSTALL="${INFERENCE_PIP_INSTALL:-false}"
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

export EXPERIMENT_NAMESPACE INFERENCE_MODEL_ID INFERENCE_MODEL_RELATIVE_PATH
export INFERENCE_MODEL_SAFE_NAME INFERENCE_POD_NAME INFERENCE_IMAGE INFERENCE_PIP_INSTALL
export INFERENCE_PIP_PACKAGES
export INFERENCE_MAX_NEW_TOKENS INFERENCE_SLEEP_SECONDS INFERENCE_GPU_MEMORY_MB INFERENCE_GPU_CORE_PERCENT
export MODEL_NFS_SERVER MODEL_NFS_EXPORT_PATH GPU_CR_LIB_HOST_PATH GCR_CONTROL_DIR GCR_DATA_DIR CHECKPOINT_STORAGE_PATH
export GCR_REMOTE_SINK GCR_REMOTE_HOST GCR_REMOTE_PORT GCR_REMOTE_REQUIRED

kubectl_apply "${REPO_ROOT}/manifests/namespace.yaml"
kubectl_apply "${REPO_ROOT}/manifests/rbac.yaml"

if [[ "${DRY_RUN}" != "true" ]]; then
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${INFERENCE_POD_NAME}" --ignore-not-found=true --wait=true
fi

if [[ -n "${NODE}" ]]; then
  rendered="${RESULT_DIR}/inference-pod.yaml"
  envsubst < "${REPO_ROOT}/manifests/inference-overhead-pod.yaml" > "${rendered}"
  cat >> "${rendered}" <<EOF
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
EOF
  if [[ "${DRY_RUN}" == "true" ]]; then
    kubectl apply --dry-run=server -f "${rendered}"
  else
    kubectl apply -f "${rendered}"
  fi
else
  if [[ "${DRY_RUN}" == "true" ]]; then
    envsubst < "${REPO_ROOT}/manifests/inference-overhead-pod.yaml" | kubectl apply --dry-run=server -f -
  else
    envsubst < "${REPO_ROOT}/manifests/inference-overhead-pod.yaml" | kubectl apply -f -
  fi
fi

if [[ "${DRY_RUN}" != "true" ]]; then
  kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready "pod/${INFERENCE_POD_NAME}" --timeout="${INFERENCE_READY_TIMEOUT_SECONDS:-900}s"
  capture pod kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${INFERENCE_POD_NAME}" -o yaml
  capture logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${INFERENCE_POD_NAME}" --tail=120
  node_name="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${INFERENCE_POD_NAME}" -o jsonpath='{.spec.nodeName}')"
  pod_uid="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${INFERENCE_POD_NAME}" -o jsonpath='{.metadata.uid}')"
  hami_allocation="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${INFERENCE_POD_NAME}" -o jsonpath='{.metadata.annotations.hami\.io/vgpu-devices-allocated}' 2>/dev/null || true)"
  write_state "last-inference-overhead-pod" "${INFERENCE_POD_NAME}"
  write_state "last-inference-overhead-model" "${MODEL}"
  write_state "last-inference-overhead-node" "${node_name}"
  write_state "last-inference-overhead-pod-uid" "${pod_uid}"
  write_state "last-inference-overhead-hami-allocation" "${hami_allocation}"
  append_summary "# Inference Workload" "" "- model: ${MODEL}" "- pod: ${INFERENCE_POD_NAME}" "- node: ${node_name}" "- pod-uid: ${pod_uid}" "- hami-allocation: ${hami_allocation:-UNKNOWN}" "- model-path: nfs://${MODEL_NFS_SERVER}${MODEL_NFS_EXPORT_PATH}/models/${INFERENCE_MODEL_RELATIVE_PATH}"
fi
