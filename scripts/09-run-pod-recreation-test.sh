#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir pod-recreation
require_kubectl
require_cmd envsubst
confirm_destructive "Deleting Pod A and creating restore Pod from GPUCheckpoint artifacts"

state_dir="${REPO_ROOT}/${STATE_ROOT#./}"
RESTORE_CHECKPOINT_URI="${RESTORE_CHECKPOINT_URI:-$(cat "${state_dir}/last-checkpoint-uri" 2>/dev/null || true)}"
RESTORE_DATA_URI="${RESTORE_DATA_URI:-$(cat "${state_dir}/last-checkpoint-data-uri" 2>/dev/null || true)}"
RESTORE_SOURCE_POD_UID="${RESTORE_SOURCE_POD_UID:-$(cat "${state_dir}/last-checkpoint-source-pod-uid" 2>/dev/null || true)}"
RESTORE_GPU_UUID="${RESTORE_GPU_UUID:-$(cat "${state_dir}/last-hami-gpu-uuid" 2>/dev/null || true)}"
RESTORE_BLOB_MODE="${RESTORE_BLOB_MODE:-copy}"
observed_node="$(cat "${state_dir}/last-checkpoint-observed-node" 2>/dev/null || true)"
TARGET_NODE="${TARGET_NODE:-${observed_node}}"

[[ -n "${RESTORE_CHECKPOINT_URI}" ]] || die "Missing restore checkpoint URI. Run scripts/08-run-gcr-criu-selective-test.sh --yes first."
[[ -n "${RESTORE_SOURCE_POD_UID}" ]] || die "Missing source Pod UID. Run scripts/08-run-gcr-criu-selective-test.sh --yes first."
[[ -n "${TARGET_NODE}" ]] || die "TARGET_NODE is empty and checkpoint observed node was not recorded."
[[ -n "${RESTORE_GPU_UUID}" ]] || die "Missing HAMi GPU UUID. Re-run scripts/08-run-gcr-criu-selective-test.sh --yes with a HAMi-bound Pod A, or set RESTORE_GPU_UUID manually."
export RESTORE_CHECKPOINT_URI RESTORE_DATA_URI RESTORE_SOURCE_POD_UID RESTORE_GPU_UUID RESTORE_BLOB_MODE TARGET_NODE

capture restore-manifest bash -lc "envsubst < '${REPO_ROOT}/manifests/restore-pod.yaml'"

run_cmd kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod hami-pod-a --ignore-not-found=true
run_cmd kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod hami-pod-a-restored --ignore-not-found=true
if [[ "${DRY_RUN}" == "true" ]]; then
  envsubst < "${REPO_ROOT}/manifests/restore-pod.yaml" | kubectl apply --dry-run=server -f -
else
  envsubst < "${REPO_ROOT}/manifests/restore-pod.yaml" | kubectl apply -f -
  kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready pod/hami-pod-a-restored --timeout="${RESTORE_TIMEOUT_SECONDS:-300}s"
fi
capture pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -o wide
capture restored-pod kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod hami-pod-a-restored
capture restored-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-a-restored --tail=200
capture pod-b-after-restore kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=200
append_summary "# Pod A Restore" "" "- restore pod: hami-pod-a-restored" "- checkpoint-uri: ${RESTORE_CHECKPOINT_URI}" "- data-uri: ${RESTORE_DATA_URI:-default .tar -> .blob}" "- source-pod-uid: ${RESTORE_SOURCE_POD_UID}" "- target-node: ${TARGET_NODE}" "- hami-gpu-uuid: ${RESTORE_GPU_UUID}"
