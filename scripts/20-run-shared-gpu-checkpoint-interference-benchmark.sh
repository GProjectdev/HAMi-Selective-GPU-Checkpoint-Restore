#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

MODEL=""
GROUP=""
BASELINE_SECONDS=60
POST_SECONDS=60
SAMPLE_INTERVAL_SECONDS=2
REPEAT=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) shift; MODEL="${1:?missing model}" ;;
    --group) shift; GROUP="${1:?missing group}" ;;
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
init_result_dir "shared-gpu-checkpoint-interference-${MODEL:-current}"
require_kubectl
confirm_destructive "Running shared-GPU checkpoint interference benchmark"
[[ "${DRY_RUN}" == "true" ]] && die "This benchmark needs live sampling and cannot run with --dry-run."

GROUP="${GROUP:-$(cat "${REPO_ROOT}/${STATE_ROOT#./}/last-shared-gpu-interference-group" 2>/dev/null || true)}"
MODEL="${MODEL:-$(cat "${REPO_ROOT}/${STATE_ROOT#./}/last-shared-gpu-interference-model" 2>/dev/null || echo unknown)}"
[[ -n "${GROUP}" ]] || die "Set --group or run scripts/19-deploy-shared-gpu-interference-workloads.sh first."

mapfile -t PODS < <(kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -l "experiment.gpu-cr/group=${GROUP}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
(( ${#PODS[@]} >= 2 )) || die "Need at least two Running Pods in group ${GROUP}."

for pod in "${PODS[@]}"; do
  kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready "pod/${pod}" --timeout=30s
done

WORKLOAD_NODE="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${PODS[0]}" -o jsonpath='{.spec.nodeName}')"
for pod in "${PODS[@]}"; do
  node="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
  [[ "${node}" == "${WORKLOAD_NODE}" ]] || die "Pods are not on the same node: ${PODS[0]}=${WORKLOAD_NODE}, ${pod}=${node}"
done

node_top_probe="$(kubectl top node "${WORKLOAD_NODE}" --no-headers 2>&1 || true)"
if [[ -z "${node_top_probe}" || "${node_top_probe}" == error:* ]]; then
  printf '%s\n' "${node_top_probe:-kubectl top node returned no output}" > "${RESULT_DIR}/node-resource-error.txt"
  die "Node metrics are unavailable for ${WORKLOAD_NODE}. Install/fix metrics-server before measuring node-level interference."
fi

is_ready() {
  local pod="$1"
  kubectl -n "${EXPERIMENT_NAMESPACE}" exec "${pod}" -- sh -c 'test -f /tmp/hami_interference_ready' >/dev/null 2>&1 && return 0
  kubectl --request-timeout=10s -n "${EXPERIMENT_NAMESPACE}" logs "${pod}" --tail=300 2>/dev/null | grep -q '\[interference\].*iteration='
}

log "Waiting for steady-state evidence from ${#PODS[@]} Pods"
deadline=$((SECONDS + ${INFERENCE_READY_TIMEOUT_SECONDS:-900}))
while (( SECONDS < deadline )); do
  ready_count=0
  for pod in "${PODS[@]}"; do
    if is_ready "${pod}"; then
      ready_count=$((ready_count + 1))
    fi
  done
  (( ready_count == ${#PODS[@]} )) && break
  sleep 5
done
for pod in "${PODS[@]}"; do
  is_ready "${pod}" || die "Pod ${pod} did not reach steady-state."
done

printf 'timestamp_utc,repeat,scenario,phase,node,cpu,cpu_percent,memory,memory_percent\n' > "${RESULT_DIR}/node-resource-samples.csv"
printf 'timestamp_utc,repeat,scenario,phase,pod,container,cpu,memory\n' > "${RESULT_DIR}/pod-resource-samples.csv"
printf 'timestamp_utc,repeat,scenario,phase,gpu_timestamp,gpu_uuid,gpu_util_percent,mem_util_percent,gpu_mem_used_mb,gpu_mem_free_mb,power_w\n' > "${RESULT_DIR}/gpu-samples.csv"
printf 'repeat,scenario,target_pods,start_epoch,end_epoch,duration_ms,status\n' > "${RESULT_DIR}/checkpoint-durations.csv"

sample_once() {
  local repeat_id="$1"
  local scenario="$2"
  local phase="$3"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  while read -r node cpu cpu_percent memory memory_percent rest; do
    [[ -n "${node}" && "${node}" != "error:" ]] || continue
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "${ts}" "${repeat_id}" "${scenario}" "${phase}" "${node}" "${cpu}" "${cpu_percent}" "${memory}" "${memory_percent}" >> "${RESULT_DIR}/node-resource-samples.csv"
  done < <(kubectl top node "${WORKLOAD_NODE}" --no-headers 2>/dev/null || true)

  for pod in "${PODS[@]}"; do
    while read -r top_pod container cpu memory rest; do
      [[ -n "${top_pod}" && "${top_pod}" != "error:" ]] || continue
      printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "${ts}" "${repeat_id}" "${scenario}" "${phase}" "${top_pod}" "${container}" "${cpu}" "${memory}" >> "${RESULT_DIR}/pod-resource-samples.csv"
    done < <(kubectl -n "${EXPERIMENT_NAMESPACE}" top pod "${pod}" --containers --no-headers 2>/dev/null || true)
  done

  {
    printf '%s,%s,%s,%s,' "${ts}" "${repeat_id}" "${scenario}" "${phase}"
    kubectl -n "${EXPERIMENT_NAMESPACE}" exec "${PODS[0]}" -- nvidia-smi \
      --query-gpu=timestamp,uuid,utilization.gpu,utilization.memory,memory.used,memory.free,power.draw \
      --format=csv,noheader,nounits 2>/dev/null | head -1 || printf 'nvidia-smi-unavailable'
    printf '\n'
  } >> "${RESULT_DIR}/gpu-samples.csv"
}

sample_for() {
  local repeat_id="$1"
  local scenario="$2"
  local phase="$3"
  local duration="$4"
  local end=$((SECONDS + duration))
  while (( SECONDS < end )); do
    sample_once "${repeat_id}" "${scenario}" "${phase}"
    sleep "${SAMPLE_INTERVAL_SECONDS}"
  done
}

capture_logs() {
  local repeat_id="$1"
  local scenario="$2"
  local phase="$3"
  for pod in "${PODS[@]}"; do
    kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${pod}" --tail=1000 > "${RESULT_DIR}/logs-${scenario}-${phase}-repeat-${repeat_id}-${pod}.txt" 2>&1 || true
  done
}

make_gpucheckpoint() {
  local name="$1"
  local pod="$2"
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete gpucheckpoint "${name}" --ignore-not-found=true >/dev/null 2>&1 || true
  cat <<EOF | kubectl apply -f -
apiVersion: gpu-cr.io/v1alpha1
kind: GPUCheckpoint
metadata:
  name: ${name}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app.kubernetes.io/name: hami-selective-cr
    experiment.gpu-cr/role: shared-gpu-interference-checkpoint
    experiment.gpu-cr/group: ${GROUP}
spec:
  workloadRef:
    kind: Pod
    namespace: ${EXPERIMENT_NAMESPACE}
    name: ${pod}
    container: inference
  storage:
    type: ${CHECKPOINT_STORAGE_TYPE}
    path: ${CHECKPOINT_STORAGE_PATH}
EOF
}

run_checkpoint_set() {
  local repeat_id="$1"
  local scenario="$2"
  shift 2
  local targets=("$@")
  local wait_pids=()
  local names=()
  local start_epoch end_epoch start_ns end_ns duration_ms status

  start_epoch="$(date +%s.%N)"
  start_ns="$(date +%s%N)"
  for pod in "${targets[@]}"; do
    name="ckpt-${scenario}-${repeat_id}-${pod}" 
    name="$(tr '[:upper:]_.' '[:lower:]--' <<<"${name}" | tr -cd 'a-z0-9-')"
    names+=("${name}")
    make_gpucheckpoint "${name}" "${pod}" &
    wait_pids+=("$!")
  done
  for pid in "${wait_pids[@]}"; do
    wait "${pid}"
  done

  wait_pids=()
  status="Completed"
  for name in "${names[@]}"; do
    kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Completed "gpucheckpoint/${name}" --timeout="${RESTORE_TIMEOUT_SECONDS:-300}s" &
    wait_pids+=("$!")
  done
  for pid in "${wait_pids[@]}"; do
    if ! wait "${pid}"; then
      status="Failed"
    fi
  done
  end_ns="$(date +%s%N)"
  end_epoch="$(date +%s.%N)"
  duration_ms="$(( (end_ns - start_ns) / 1000000 ))"
  printf '%s,%s,%s,%s,%s,%s,%s\n' "${repeat_id}" "${scenario}" "$(IFS='+'; echo "${targets[*]}")" "${start_epoch}" "${end_epoch}" "${duration_ms}" "${status}" >> "${RESULT_DIR}/checkpoint-durations.csv"

  for name in "${names[@]}"; do
    capture "gpucheckpoint-${scenario}-repeat-${repeat_id}-${name}" kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint "${name}" -o yaml
  done
}

capture initial-pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -l "experiment.gpu-cr/group=${GROUP}" -o wide
capture initial-pods-yaml kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -l "experiment.gpu-cr/group=${GROUP}" -o yaml

for repeat_id in $(seq 1 "${REPEAT}"); do
  log "Repeat ${repeat_id}/${REPEAT}: solo checkpoint baseline"
  capture_logs "${repeat_id}" "solo" "before"
  sample_for "${repeat_id}" "solo" "baseline" "${BASELINE_SECONDS}"
  run_checkpoint_set "${repeat_id}" "solo" "${PODS[0]}"
  capture_logs "${repeat_id}" "solo" "after-checkpoint"
  sample_for "${repeat_id}" "solo" "post" "${POST_SECONDS}"

  if (( ${#PODS[@]} >= 2 )); then
    log "Repeat ${repeat_id}/${REPEAT}: concurrent checkpoint with 2 Pods"
    capture_logs "${repeat_id}" "concurrent2" "before"
    sample_for "${repeat_id}" "concurrent2" "baseline" "${BASELINE_SECONDS}"
    run_checkpoint_set "${repeat_id}" "concurrent2" "${PODS[0]}" "${PODS[1]}"
    capture_logs "${repeat_id}" "concurrent2" "after-checkpoint"
    sample_for "${repeat_id}" "concurrent2" "post" "${POST_SECONDS}"
  fi

  if (( ${#PODS[@]} >= 3 )); then
    log "Repeat ${repeat_id}/${REPEAT}: concurrent checkpoint with 3 Pods"
    capture_logs "${repeat_id}" "concurrent3" "before"
    sample_for "${repeat_id}" "concurrent3" "baseline" "${BASELINE_SECONDS}"
    run_checkpoint_set "${repeat_id}" "concurrent3" "${PODS[0]}" "${PODS[1]}" "${PODS[2]}"
    capture_logs "${repeat_id}" "concurrent3" "after-checkpoint"
    sample_for "${repeat_id}" "concurrent3" "post" "${POST_SECONDS}"
  fi
done

capture final-pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -l "experiment.gpu-cr/group=${GROUP}" -o wide
for pod in "${PODS[@]}"; do
  capture "final-logs-${pod}" kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${pod}" --tail=1000
done

python3 - "${RESULT_DIR}" <<'PY'
import csv
import math
import pathlib
import sys

result = pathlib.Path(sys.argv[1])
durations = result / "checkpoint-durations.csv"
rows = list(csv.DictReader(durations.open()))
by_scenario = {}
for row in rows:
    if row["status"] != "Completed":
        continue
    by_scenario.setdefault(row["scenario"], []).append(float(row["duration_ms"]))

def avg(xs):
    return sum(xs) / len(xs) if xs else math.nan

def p95(xs):
    if not xs:
        return math.nan
    xs = sorted(xs)
    idx = min(len(xs) - 1, math.ceil(len(xs) * 0.95) - 1)
    return xs[idx]

solo = avg(by_scenario.get("solo", []))
summary_csv = result / "shared-gpu-interference-summary.csv"
with summary_csv.open("w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["scenario", "samples", "avg_duration_ms", "p95_duration_ms", "cci_factor_vs_solo"])
    for scenario in sorted(by_scenario):
        values = by_scenario[scenario]
        cci = avg(values) / solo if solo and not math.isnan(solo) else math.nan
        writer.writerow([scenario, len(values), f"{avg(values):.3f}", f"{p95(values):.3f}", f"{cci:.3f}"])

summary_md = result / "summary.md"
with summary_md.open("w", encoding="utf-8") as f:
    f.write("# Shared GPU Checkpoint Interference Benchmark\n\n")
    f.write("## Checkpoint-to-Checkpoint Interference\n\n")
    f.write("| scenario | samples | avg duration ms | p95 duration ms | CCI factor vs solo |\n")
    f.write("|---|---:|---:|---:|---:|\n")
    for scenario in sorted(by_scenario):
        values = by_scenario[scenario]
        cci = avg(values) / solo if solo and not math.isnan(solo) else math.nan
        f.write(f"| {scenario} | {len(values)} | {avg(values):.3f} | {p95(values):.3f} | {cci:.3f} |\n")
    f.write("\n## Raw Evidence\n\n")
    for name in [
        "checkpoint-durations.csv",
        "node-resource-samples.csv",
        "pod-resource-samples.csv",
        "gpu-samples.csv",
        "shared-gpu-interference-summary.csv",
    ]:
        f.write(f"- `{name}`\n")
    f.write("\n## Notes\n\n")
    f.write("- CCI factor는 concurrent checkpoint 평균 시간을 solo checkpoint 평균 시간으로 나눈 값이다.\n")
    f.write("- CEI는 `logs-*-before/after-checkpoint-*`의 latency 또는 ips 값을 checkpoint window 기준으로 별도 계산한다.\n")
    f.write("- 첫 검증에서는 CCI가 명확한지 먼저 보고, 이후 CEI 계산 window를 정밀화한다.\n")

print(f"Wrote {summary_csv}")
print(f"Wrote {summary_md}")
PY

write_state "last-shared-gpu-interference-result-dir" "${RESULT_DIR}"
log "Shared-GPU checkpoint interference benchmark completed. Result: ${RESULT_DIR}"
