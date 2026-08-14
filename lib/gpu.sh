#!/usr/bin/env bash
set -Eeuo pipefail

node_gpu_report() {
  kubectl get nodes -o json | jq -r '
    .items[] |
    [.metadata.name,
     (.status.allocatable["nvidia.com/gpu"] // "0"),
     (.metadata.labels["gpu"] // "UNKNOWN")] | @tsv'
}

pod_gpu_uuid() {
  local pod="$1"
  kubectl -n "${EXPERIMENT_NAMESPACE}" exec "${pod}" -- nvidia-smi --query-gpu=uuid,name,memory.used,memory.total --format=csv,noheader,nounits
}

