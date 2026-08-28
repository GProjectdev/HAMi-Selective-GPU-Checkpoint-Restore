#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

MODEL=""
POD_NAME=""
BASELINE_SECONDS=60
POST_SECONDS=60
SAMPLE_INTERVAL_SECONDS=2
REPEAT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) shift; MODEL="${1:?missing model}" ;;
    --pod-name) shift; POD_NAME="${1:?missing pod name}" ;;
    --baseline-seconds) shift; BASELINE_SECONDS="${1:?missing seconds}" ;;
    --post-seconds) shift; POST_SECONDS="${1:?missing seconds}" ;;
    --sample-interval-seconds) shift; SAMPLE_INTERVAL_SECONDS="${1:?missing seconds}" ;;
    --repeat) shift; REPEAT="${1:?missing repeat}" ;;
    --dry-run|--yes|-y|--env-file)
      break
      ;;
    *) die "Unknown argument before common args: $1" ;;
  esac
  shift
done

parse_common_args "$@"
load_env
init_result_dir "checkpoint-overhead-${MODEL:-current}"
require_kubectl
require_cmd envsubst
confirm_destructive "Running checkpoint overhead benchmark"

if [[ -z "${POD_NAME}" ]]; then
  if [[ -f "${REPO_ROOT}/${STATE_ROOT#./}/last-inference-overhead-pod" ]]; then
    POD_NAME="$(cat "${REPO_ROOT}/${STATE_ROOT#./}/last-inference-overhead-pod")"
  else
    die "Set --pod-name or run scripts/13-deploy-inference-overhead-workload.sh first."
  fi
fi
if [[ -z "${MODEL}" ]]; then
  MODEL="$(cat "${REPO_ROOT}/${STATE_ROOT#./}/last-inference-overhead-model" 2>/dev/null || echo unknown)"
fi

INFERENCE_MODEL_SAFE_NAME="$(tr '/:.' '---' <<<"${MODEL}" | tr -cd 'A-Za-z0-9-')"
INFERENCE_POD_NAME="${POD_NAME}"
INFERENCE_CHECKPOINT_NAME="hami-infer-${INFERENCE_MODEL_SAFE_NAME}-checkpoint"
export EXPERIMENT_NAMESPACE INFERENCE_MODEL_SAFE_NAME INFERENCE_POD_NAME INFERENCE_CHECKPOINT_NAME CHECKPOINT_STORAGE_TYPE CHECKPOINT_STORAGE_PATH

[[ "${DRY_RUN}" == "true" ]] && die "This benchmark needs live sampling and cannot run with --dry-run."
kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${POD_NAME}" >/dev/null
kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready "pod/${POD_NAME}" --timeout=30s
WORKLOAD_NODE="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.spec.nodeName}')"
[[ -n "${WORKLOAD_NODE}" ]] || die "Pod ${POD_NAME} is Ready but .spec.nodeName is empty."
REQUIRE_NODE_METRICS="${REQUIRE_NODE_METRICS:-true}"

node_top_probe="$(kubectl top node "${WORKLOAD_NODE}" --no-headers 2>&1 || true)"
if [[ -z "${node_top_probe}" || "${node_top_probe}" == error:* ]]; then
  printf '%s\n' "${node_top_probe:-kubectl top node returned no output}" > "${RESULT_DIR}/node-resource-error.txt"
  if [[ "${REQUIRE_NODE_METRICS}" == "true" ]]; then
    die "Node metrics are unavailable for ${WORKLOAD_NODE}. Check ${RESULT_DIR}/node-resource-error.txt, metrics-server, and metrics.k8s.io before running node-overhead measurements."
  fi
  log "WARN: Node metrics unavailable for ${WORKLOAD_NODE}; node-resource-samples.csv will contain unavailable markers."
fi

is_inference_steady() {
  kubectl -n "${EXPERIMENT_NAMESPACE}" exec "${POD_NAME}" -- sh -c 'test -f /tmp/hami_inference_ready' >/dev/null 2>&1 && return 0
  kubectl --request-timeout=10s -n "${EXPERIMENT_NAMESPACE}" logs "${POD_NAME}" --tail=500 2>/dev/null | grep -Eq 'starting steady inference loop|\[infer\].*iteration=[0-9]+' && return 0
  return 1
}

log "Waiting for inference steady-state evidence from ${POD_NAME}"
steady_deadline=$((SECONDS + ${INFERENCE_READY_TIMEOUT_SECONDS:-900}))
while (( SECONDS < steady_deadline )); do
  if is_inference_steady; then
    break
  fi
  sleep 5
done
if ! is_inference_steady; then
  capture not-steady-pod kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${POD_NAME}" -o yaml
  capture not-steady-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${POD_NAME}" --tail=500
  die "Inference workload did not reach steady-state. Check ${RESULT_DIR}/not-steady-logs.txt"
fi
log "Inference steady-state evidence found for ${POD_NAME}"

sample_once() {
  local phase="$1"
  local repeat_id="$2"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  {
    printf '=== %s repeat=%s phase=%s pod-top ===\n' "${ts}" "${repeat_id}" "${phase}"
    kubectl -n "${EXPERIMENT_NAMESPACE}" top pod "${POD_NAME}" --containers 2>&1 || true
    printf '=== %s repeat=%s phase=%s gpu-cr-top ===\n' "${ts}" "${repeat_id}" "${phase}"
    kubectl -n "${GPU_CR_NAMESPACE:-gpu-cr-system}" top pod 2>&1 || true
    printf '=== %s repeat=%s phase=%s hami-top ===\n' "${ts}" "${repeat_id}" "${phase}"
    kubectl -n kube-system top pod 2>&1 | grep -Ei 'hami|nvidia-device' || true
    printf '=== %s repeat=%s phase=%s workload-node-top ===\n' "${ts}" "${repeat_id}" "${phase}"
    kubectl top node "${WORKLOAD_NODE}" 2>&1 || true
  } >> "${RESULT_DIR}/k8s-top-samples.txt"

  while read -r node cpu cpu_percent memory memory_percent rest; do
    [[ -n "${node}" && "${node}" != "error:" ]] || continue
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "${ts}" "${repeat_id}" "${phase}" "${node}" "${cpu}" "${cpu_percent}" "${memory}" "${memory_percent}" >> "${RESULT_DIR}/node-resource-samples.csv"
  done < <(kubectl top node "${WORKLOAD_NODE}" --no-headers 2>/dev/null || true)
  if ! kubectl top node "${WORKLOAD_NODE}" --no-headers >/dev/null 2>&1; then
    printf '%s,%s,%s,%s,unavailable,unavailable,unavailable,unavailable\n' "${ts}" "${repeat_id}" "${phase}" "${WORKLOAD_NODE}" >> "${RESULT_DIR}/node-resource-samples.csv"
  fi

  while read -r pod container cpu memory rest; do
    [[ -n "${pod}" && "${pod}" != "error:" ]] || continue
    printf '%s,%s,%s,%s,%s,%s,%s\n' "${ts}" "${repeat_id}" "${phase}" "${pod}" "${container}" "${cpu}" "${memory}" >> "${RESULT_DIR}/pod-resource-samples.csv"
  done < <(kubectl -n "${EXPERIMENT_NAMESPACE}" top pod "${POD_NAME}" --containers --no-headers 2>/dev/null || true)

  while read -r pod cpu memory rest; do
    [[ -n "${pod}" && "${pod}" != "error:" ]] || continue
    printf '%s,%s,%s,gpu-cr-system,%s,%s,%s\n' "${ts}" "${repeat_id}" "${phase}" "${pod}" "${cpu}" "${memory}" >> "${RESULT_DIR}/control-resource-samples.csv"
  done < <(kubectl -n "${GPU_CR_NAMESPACE:-gpu-cr-system}" top pod --no-headers 2>/dev/null || true)

  while read -r pod cpu memory rest; do
    [[ -n "${pod}" && "${pod}" != "error:" ]] || continue
    case "${pod}" in
      *hami*|*nvidia-device*)
        printf '%s,%s,%s,kube-system,%s,%s,%s\n' "${ts}" "${repeat_id}" "${phase}" "${pod}" "${cpu}" "${memory}" >> "${RESULT_DIR}/control-resource-samples.csv"
        ;;
    esac
  done < <(kubectl -n kube-system top pod --no-headers 2>/dev/null || true)

  {
    printf '%s,%s,%s,' "${ts}" "${repeat_id}" "${phase}"
    kubectl -n "${EXPERIMENT_NAMESPACE}" exec "${POD_NAME}" -- nvidia-smi \
      --query-gpu=timestamp,uuid,utilization.gpu,utilization.memory,memory.used,memory.free,power.draw \
      --format=csv,noheader,nounits 2>/dev/null | head -1 || printf 'nvidia-smi-unavailable'
    printf '\n'
  } >> "${RESULT_DIR}/gpu-samples.csv"
}

sample_for() {
  local phase="$1"
  local repeat_id="$2"
  local duration="$3"
  local end=$((SECONDS + duration))
  while (( SECONDS < end )); do
    sample_once "${phase}" "${repeat_id}"
    sleep "${SAMPLE_INTERVAL_SECONDS}"
  done
}

printf 'timestamp_utc,repeat,phase,gpu_timestamp,gpu_uuid,gpu_util_percent,mem_util_percent,gpu_mem_used_mb,gpu_mem_free_mb,power_w\n' > "${RESULT_DIR}/gpu-samples.csv"
printf 'timestamp_utc,repeat,phase,node,cpu,cpu_percent,memory,memory_percent\n' > "${RESULT_DIR}/node-resource-samples.csv"
printf 'timestamp_utc,repeat,phase,pod,container,cpu,memory\n' > "${RESULT_DIR}/pod-resource-samples.csv"
printf 'timestamp_utc,repeat,phase,namespace,pod,cpu,memory\n' > "${RESULT_DIR}/control-resource-samples.csv"
printf 'repeat,duration_ms,observed_node,checkpoint_count,checkpoint_path\n' > "${RESULT_DIR}/checkpoint-durations.csv"

capture initial-pod kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${POD_NAME}" -o yaml
capture initial-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${POD_NAME}" --tail=120

for repeat_id in $(seq 1 "${REPEAT}"); do
  log "Repeat ${repeat_id}/${REPEAT}: sampling baseline for ${BASELINE_SECONDS}s"
  sample_for baseline "${repeat_id}" "${BASELINE_SECONDS}"

  log "Repeat ${repeat_id}/${REPEAT}: running GPUCheckpoint while sampling"
  sampler_pid=""
  sample_for checkpoint "${repeat_id}" "${RESTORE_TIMEOUT_SECONDS:-300}" &
  sampler_pid=$!

  start_ns="$(date +%s%N)"
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete gpucheckpoint "${INFERENCE_CHECKPOINT_NAME}" --ignore-not-found=true >/dev/null 2>&1 || true
  envsubst < "${REPO_ROOT}/manifests/inference-gpucheckpoint.yaml" | kubectl apply -f -
  kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Completed "gpucheckpoint/${INFERENCE_CHECKPOINT_NAME}" --timeout="${RESTORE_TIMEOUT_SECONDS:-300}s"
  end_ns="$(date +%s%N)"

  if [[ -n "${sampler_pid}" ]]; then
    kill "${sampler_pid}" >/dev/null 2>&1 || true
    wait "${sampler_pid}" >/dev/null 2>&1 || true
  fi

  checkpoint_path="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint "${INFERENCE_CHECKPOINT_NAME}" -o jsonpath='{.status.lastCheckpointPath}' 2>/dev/null || true)"
  checkpoint_count="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint "${INFERENCE_CHECKPOINT_NAME}" -o jsonpath='{.status.checkpointCount}' 2>/dev/null || true)"
  observed_node="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint "${INFERENCE_CHECKPOINT_NAME}" -o jsonpath='{.status.observedNode}' 2>/dev/null || true)"
  source_pod_uid="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint "${INFERENCE_CHECKPOINT_NAME}" -o jsonpath='{.status.podUID}' 2>/dev/null || true)"
  hami_allocation="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.metadata.annotations.hami\.io/vgpu-devices-allocated}' 2>/dev/null || true)"
  hami_gpu_uuid="$(awk -F, '{print $1}' <<<"${hami_allocation}")"
  duration_ms="$(( (end_ns - start_ns) / 1000000 ))"
  printf '%s,%s,%s,%s,%s\n' "${repeat_id}" "${duration_ms}" "${observed_node}" "${checkpoint_count:-}" "${checkpoint_path}" >> "${RESULT_DIR}/checkpoint-durations.csv"
  if [[ -n "${checkpoint_path}" ]]; then
    write_state last-checkpoint-path "${checkpoint_path}"
    write_state last-checkpoint-uri "hostpath://${checkpoint_path}"
    write_state last-checkpoint-data-uri "hostpath://${checkpoint_path%.tar}.blob"
    write_state last-checkpoint-source-pod-uid "${source_pod_uid}"
    write_state last-checkpoint-observed-node "${observed_node}"
    write_state last-checkpoint-container "inference"
    write_state last-hami-gpu-allocation "${hami_allocation}"
    write_state last-hami-gpu-uuid "${hami_gpu_uuid}"
    {
      printf '=== repeat=%s checkpoint artifacts ===\n' "${repeat_id}"
      kubectl -n "${EXPERIMENT_NAMESPACE}" exec "${POD_NAME}" -- \
        sh -c "ls -lh '${checkpoint_path}' '${checkpoint_path%.tar}.blob' 2>/dev/null || true"
    } >> "${RESULT_DIR}/checkpoint-artifact-sizes.txt" 2>&1 || true
  fi
  capture "gpucheckpoint-repeat-${repeat_id}" kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint "${INFERENCE_CHECKPOINT_NAME}" -o yaml
  capture "logs-after-repeat-${repeat_id}" kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${POD_NAME}" --tail=240

  log "Repeat ${repeat_id}/${REPEAT}: sampling post-checkpoint for ${POST_SECONDS}s"
  sample_for post "${repeat_id}" "${POST_SECONDS}"
done

capture final-pod kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${POD_NAME}" -o yaml
capture final-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${POD_NAME}" --tail=240

bash "${REPO_ROOT}/scripts/15-summarize-checkpoint-overhead-results.sh" --result-dir "${RESULT_DIR}"

{
  printf '# Checkpoint Overhead Benchmark\n\n'
  printf -- '- model: %s\n' "${MODEL}"
  printf -- '- pod: %s\n' "${POD_NAME}"
  printf -- '- workload node: %s\n' "${WORKLOAD_NODE}"
  printf -- '- baseline window: %ss\n' "${BASELINE_SECONDS}"
  printf -- '- post window: %ss\n' "${POST_SECONDS}"
  printf -- '- sample interval: %ss\n' "${SAMPLE_INTERVAL_SECONDS}"
  printf -- '- repeat: %s\n\n' "${REPEAT}"
  printf '## Checkpoint Durations\n\n'
  printf '```csv\n'
  cat "${RESULT_DIR}/checkpoint-durations.csv"
  printf '```\n\n'
  printf '## Raw Evidence\n\n'
  printf -- '- gpu-samples.csv\n'
  printf -- '- node-resource-samples.csv\n'
  printf -- '- pod-resource-samples.csv\n'
  printf -- '- control-resource-samples.csv\n'
  printf -- '- k8s-top-samples.txt\n'
  printf -- '- checkpoint-artifact-sizes.txt\n'
  printf -- '- overhead-summary.csv\n'
  printf -- '- overhead-summary.md\n'
  printf -- '- gpucheckpoint-repeat-*.txt\n'
  printf -- '- logs-after-repeat-*.txt\n'
  printf '\n'
  if [[ -f "${RESULT_DIR}/overhead-summary.md" ]]; then
    printf '## Calculated Overhead Deltas\n\n'
    sed -n '/## Delta Table/,$p' "${RESULT_DIR}/overhead-summary.md"
  fi
} > "${RESULT_DIR}/summary.md"

write_state "last-checkpoint-overhead-result-dir" "${RESULT_DIR}"
log "Checkpoint overhead benchmark completed. Result: ${RESULT_DIR}"
