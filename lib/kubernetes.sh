#!/usr/bin/env bash
set -Eeuo pipefail

list_gpu_nodes() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null || true
}

detect_source_node() {
  if [[ -n "${SOURCE_NODE:-}" ]]; then
    printf '%s\n' "${SOURCE_NODE}"
    return
  fi
  list_gpu_nodes | awk '$2 != "" && $2 != "0" {print $1; exit}'
}

detect_target_node() {
  if [[ -n "${TARGET_NODE:-}" ]]; then
    printf '%s\n' "${TARGET_NODE}"
    return
  fi
  local source
  source="$(detect_source_node)"
  list_gpu_nodes | awk -v s="${source}" '$1 != s && $2 != "" && $2 != "0" {print $1; exit}'
}

kubectl_apply() {
  local file="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    kubectl apply --dry-run=server -f "${file}"
  else
    kubectl apply -f "${file}"
  fi
}

wait_pod_ready() {
  local pod="$1"
  kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready "pod/${pod}" --timeout=300s
}

