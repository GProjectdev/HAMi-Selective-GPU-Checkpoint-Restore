#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir selective-gcr-criu
require_kubectl
require_cmd envsubst
confirm_destructive "Creating GPUCheckpoint for Pod A"

[[ -n "${CHECKPOINT_STORAGE_TYPE:-}" ]] || die "Set CHECKPOINT_STORAGE_TYPE."
[[ -n "${CHECKPOINT_STORAGE_PATH:-}" ]] || die "Set CHECKPOINT_STORAGE_PATH."

if ! kubectl api-resources --no-headers 2>/dev/null | awk '$NF == "GPUCheckpoint" {found=1} END {exit !found}'; then
  kubectl api-resources > "${RESULT_DIR}/api-resources.txt" 2>&1 || true
  kubectl get crd > "${RESULT_DIR}/crds.txt" 2>&1 || true
  die "GPUCheckpoint CRD is not installed. Install K8s-Native-Fast-GPU-Checkpoint-Restore-System CRD and Node Agent first, then retry. Evidence: ${RESULT_DIR}/api-resources.txt and ${RESULT_DIR}/crds.txt"
fi

capture pod-a-before kubectl -n "${EXPERIMENT_NAMESPACE}" get pod hami-pod-a -o yaml
capture pod-b-before kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=100

if [[ "${DRY_RUN}" == "true" ]]; then
  envsubst < "${REPO_ROOT}/manifests/checkpoint-resources.yaml" | kubectl apply --dry-run=server -f -
else
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete gpucheckpoint hami-pod-a-checkpoint --ignore-not-found=true >/dev/null 2>&1 || true
  envsubst < "${REPO_ROOT}/manifests/checkpoint-resources.yaml" | kubectl apply -f -
  kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Completed gpucheckpoint/hami-pod-a-checkpoint --timeout="${RESTORE_TIMEOUT_SECONDS:-300}s"
fi

checkpoint_path="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint hami-pod-a-checkpoint -o jsonpath='{.status.lastCheckpointPath}' 2>/dev/null || true)"
source_pod_uid="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint hami-pod-a-checkpoint -o jsonpath='{.status.podUID}' 2>/dev/null || true)"
observed_node="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint hami-pod-a-checkpoint -o jsonpath='{.status.observedNode}' 2>/dev/null || true)"

[[ -n "${checkpoint_path}" ]] || die "GPUCheckpoint completed but status.lastCheckpointPath is empty."
[[ -n "${source_pod_uid}" ]] || die "GPUCheckpoint completed but status.podUID is empty."

restore_checkpoint_uri="hostpath://${checkpoint_path}"
restore_data_uri="hostpath://${checkpoint_path%.tar}.blob"
write_state last-checkpoint-path "${checkpoint_path}"
write_state last-checkpoint-uri "${restore_checkpoint_uri}"
write_state last-checkpoint-data-uri "${restore_data_uri}"
write_state last-checkpoint-source-pod-uid "${source_pod_uid}"
write_state last-checkpoint-observed-node "${observed_node}"

capture checkpoint-objects kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint hami-pod-a-checkpoint -o yaml
capture pod-a-after kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-a --tail=500
capture pod-b-after kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=100

if [[ "${REQUIRE_GCR_SELECTIVE_DATA:-true}" == "true" ]]; then
  pod_a_logs="$(kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-a --tail=800 2>/dev/null || true)"
  if ! grep -Eq '\[gcr\]\[engine\] freeze: [1-9][0-9]* segs' <<<"${pod_a_logs}"; then
    die "GPUCheckpoint completed but Pod A logs do not show a GCR selective data freeze. Check that Pod A was rebuilt with shared cudart, then recreate Pod A/B and retry."
  fi
fi
append_summary "# Selective Checkpoint" "" "- GPUCheckpoint hami-pod-a-checkpoint completed." "- checkpoint-uri: ${restore_checkpoint_uri}" "- data-uri: ${restore_data_uri}" "- source-pod-uid: ${source_pod_uid}" "- observed-node: ${observed_node:-UNKNOWN}" "- Pod B before/after logs captured."
