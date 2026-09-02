#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

MODEL=""
GROUP="shared-gpu-interference"
BASELINE_SECONDS=60
POST_SECONDS=60
SAMPLE_INTERVAL_SECONDS=1
REPEAT=5
STAGGER_SECONDS=5
CHECKPOINT_COOLDOWN_SECONDS=30
RECREATE_BETWEEN_REPEATS=false
RECREATE_BETWEEN_SCENARIOS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) shift; MODEL="${1:?missing model}" ;;
    --group) shift; GROUP="${1:?missing group}" ;;
    --baseline-seconds) shift; BASELINE_SECONDS="${1:?missing seconds}" ;;
    --post-seconds) shift; POST_SECONDS="${1:?missing seconds}" ;;
    --sample-interval-seconds) shift; SAMPLE_INTERVAL_SECONDS="${1:?missing seconds}" ;;
    --repeat) shift; REPEAT="${1:?missing repeat}" ;;
    --stagger-seconds) shift; STAGGER_SECONDS="${1:?missing seconds}" ;;
    --checkpoint-cooldown-seconds) shift; CHECKPOINT_COOLDOWN_SECONDS="${1:?missing seconds}" ;;
    --recreate-between-repeats) RECREATE_BETWEEN_REPEATS=true ;;
    --recreate-between-scenarios) RECREATE_BETWEEN_SCENARIOS=true ;;
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
WORKLOAD_KIND="$(cat "${REPO_ROOT}/${STATE_ROOT#./}/last-shared-gpu-interference-workload-kind" 2>/dev/null || echo model)"
[[ -n "${GROUP}" ]] || die "Set --group or run scripts/19-deploy-shared-gpu-interference-workloads.sh first."
MODEL_SAFE_NAME="$(tr '/:.' '---' <<<"${MODEL}" | tr -cd 'A-Za-z0-9-')"

discover_pods_by_selector() {
  local selector="$1"
  kubectl -n "${EXPERIMENT_NAMESPACE}" get pods \
    -l "${selector}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort
}

refresh_pods() {
  local pod
  mapfile -t PODS < <(discover_pods_by_selector "experiment.gpu-cr/group=${GROUP}")
  if (( ${#PODS[@]} < 2 )); then
    mapfile -t PODS < <(
      discover_pods_by_selector "experiment.gpu-cr/role=shared-gpu-interference" |
        grep -E "^hami-interf-${MODEL_SAFE_NAME}-[a-z]+$" || true
    )
  fi
  if (( ${#PODS[@]} < 2 )); then
    die "Need at least two Running shared-GPU interference Pods. Run scripts/19-deploy-shared-gpu-interference-workloads.sh first, or ensure Pods have experiment.gpu-cr/group=${GROUP}."
  fi
  for pod in "${PODS[@]}"; do
    kubectl -n "${EXPERIMENT_NAMESPACE}" label pod "${pod}" "experiment.gpu-cr/group=${GROUP}" --overwrite >/dev/null 2>&1 || true
  done
  for pod in "${PODS[@]}"; do
    kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready "pod/${pod}" --timeout=60s
  done
  WORKLOAD_NODE="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${PODS[0]}" -o jsonpath='{.spec.nodeName}')"
  for pod in "${PODS[@]}"; do
    node="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
    [[ "${node}" == "${WORKLOAD_NODE}" ]] || die "Pods are not on the same node: ${PODS[0]}=${WORKLOAD_NODE}, ${pod}=${node}"
  done
}

is_ready() {
  local pod="$1"
  kubectl -n "${EXPERIMENT_NAMESPACE}" exec "${pod}" -- sh -c 'test -f /tmp/hami_interference_ready' >/dev/null 2>&1 && return 0
  kubectl --request-timeout=10s -n "${EXPERIMENT_NAMESPACE}" logs "${pod}" --tail=300 2>/dev/null | grep -q '\[interference\].*iteration='
}

wait_for_steady_state() {
  log "Waiting for steady-state evidence from ${#PODS[@]} Pods"
  local deadline ready_count pod
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
}

refresh_pods
node_top_probe="$(kubectl top node "${WORKLOAD_NODE}" --no-headers 2>&1 || true)"
if [[ -z "${node_top_probe}" || "${node_top_probe}" == error:* ]]; then
  printf '%s\n' "${node_top_probe:-kubectl top node returned no output}" > "${RESULT_DIR}/node-resource-error.txt"
  die "Node metrics are unavailable for ${WORKLOAD_NODE}. Install/fix metrics-server before measuring node-level interference."
fi
wait_for_steady_state

printf 'timestamp_utc,repeat,scenario,phase,node,cpu,cpu_percent,memory,memory_percent\n' > "${RESULT_DIR}/node-resource-samples.csv"
printf 'timestamp_utc,repeat,scenario,phase,pod,container,cpu,memory\n' > "${RESULT_DIR}/pod-resource-samples.csv"
printf 'timestamp_utc,repeat,scenario,phase,gpu_timestamp,gpu_uuid,gpu_util_percent,mem_util_percent,gpu_mem_used_mb,gpu_mem_free_mb,power_w\n' > "${RESULT_DIR}/gpu-samples.csv"
printf 'repeat,scenario,concurrency,target_pod,start_epoch,end_epoch,duration_ms,status,checkpoint_path,payload_bytes\n' > "${RESULT_DIR}/checkpoint-durations.csv"
printf 'repeat,scenario,concurrency,target_pods,start_epoch,end_epoch,makespan_ms,status,total_payload_bytes\n' > "${RESULT_DIR}/checkpoint-makespan.csv"

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
  local end
  end=$((SECONDS + duration))
  while (( SECONDS < end )); do
    sample_once "${repeat_id}" "${scenario}" "${phase}"
    sleep "${SAMPLE_INTERVAL_SECONDS}"
  done
}

make_gpucheckpoint() {
  local name="$1"
  local pod="$2"
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete gpucheckpoint "${name}" --ignore-not-found=true >/dev/null 2>&1 || true
  cat <<EOF | kubectl apply -f - >/dev/null
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

checkpoint_payload_bytes() {
  local pod="$1"
  local checkpoint_path="$2"
  local output
  [[ -n "${checkpoint_path}" ]] || { printf '0'; return; }
  output="$(
    kubectl -n "${EXPERIMENT_NAMESPACE}" exec "${pod}" -- sh -c "
    total=0
    for f in '${checkpoint_path}' '${checkpoint_path%.tar}.blob' '${checkpoint_path%.tar}.hami-runtime.tar'; do
      if [ -f \"\$f\" ]; then
        size=\$(stat -c %s \"\$f\" 2>/dev/null || echo 0)
        total=\$((total + size))
      fi
    done
    echo \"\$total\"
  " 2>/dev/null | tail -1 || true
  )"
  if [[ "${output}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${output}"
  else
    printf '0'
  fi
}

sanitize_name() {
  tr '[:upper:]_.' '[:lower:]--' <<<"$1" | tr -cd 'a-z0-9-' | cut -c1-240
}

run_one_checkpoint() {
  local repeat_id="$1"
  local scenario="$2"
  local concurrency="$3"
  local pod="$4"
  local name="$5"
  local out="$6"
  local start_epoch end_epoch start_ns end_ns duration_ms status checkpoint_path payload_bytes

  start_epoch="$(date +%s.%N)"
  start_ns="$(date +%s%N)"
  status="Completed"
  make_gpucheckpoint "${name}" "${pod}"
  if ! kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Completed "gpucheckpoint/${name}" --timeout="${RESTORE_TIMEOUT_SECONDS:-300}s" >/dev/null 2>&1; then
    status="Failed"
  fi
  end_ns="$(date +%s%N)"
  end_epoch="$(date +%s.%N)"
  duration_ms="$(( (end_ns - start_ns) / 1000000 ))"
  checkpoint_path="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint "${name}" -o jsonpath='{.status.lastCheckpointPath}' 2>/dev/null || true)"
  payload_bytes="$(checkpoint_payload_bytes "${pod}" "${checkpoint_path}")"
  [[ "${payload_bytes}" =~ ^[0-9]+$ ]] || payload_bytes=0
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "${repeat_id}" "${scenario}" "${concurrency}" "${pod}" "${start_epoch}" "${end_epoch}" "${duration_ms}" "${status}" "${checkpoint_path}" "${payload_bytes}" > "${out}"
}

record_makespan() {
  local repeat_id="$1"
  local scenario="$2"
  local concurrency="$3"
  local targets_joined="$4"
  shift 4
  python3 - "${repeat_id}" "${scenario}" "${concurrency}" "${targets_joined}" "${RESULT_DIR}/checkpoint-makespan.csv" "$@" <<'PY'
import csv
import sys

repeat_id, scenario, concurrency, targets, out_path, *files = sys.argv[1:]
rows = []
for path in files:
    with open(path, newline="") as f:
        rows.extend(csv.DictReader(f, fieldnames=[
            "repeat", "scenario", "concurrency", "target_pod", "start_epoch",
            "end_epoch", "duration_ms", "status", "checkpoint_path", "payload_bytes"
        ]))

starts = [float(r["start_epoch"]) for r in rows]
ends = [float(r["end_epoch"]) for r in rows]
status = "Completed" if rows and all(r["status"] == "Completed" for r in rows) else "Failed"
payload = sum(int(r["payload_bytes"] or 0) for r in rows)
makespan_ms = int((max(ends) - min(starts)) * 1000) if rows else 0
with open(out_path, "a", newline="") as f:
    writer = csv.writer(f)
    writer.writerow([repeat_id, scenario, concurrency, targets, min(starts), max(ends), makespan_ms, status, payload])
PY
}

run_checkpoint_set() {
  local repeat_id="$1"
  local scenario="$2"
  local mode="$3"
  shift 3
  local targets=("$@")
  local concurrency="${#targets[@]}"
  local pids=()
  local row_files=()
  local idx=0 pod name row_file

  for pod in "${targets[@]}"; do
    name="$(sanitize_name "ckpt-${scenario}-${repeat_id}-${pod}")"
    row_file="${RESULT_DIR}/.checkpoint-${scenario}-${repeat_id}-${idx}.csv"
    row_files+=("${row_file}")
    run_one_checkpoint "${repeat_id}" "${scenario}" "${concurrency}" "${pod}" "${name}" "${row_file}" &
    pids+=("$!")
    idx=$((idx + 1))
    if [[ "${mode}" == "sequential" ]]; then
      wait "${pids[-1]}"
    elif [[ "${mode}" == "staggered" && "${idx}" -lt "${concurrency}" ]]; then
      sleep "${STAGGER_SECONDS}"
    fi
  done
  for pid in "${pids[@]}"; do
    wait "${pid}" || true
  done
  for row_file in "${row_files[@]}"; do
    cat "${row_file}" >> "${RESULT_DIR}/checkpoint-durations.csv"
  done
  record_makespan "${repeat_id}" "${scenario}" "${concurrency}" "$(IFS='+'; echo "${targets[*]}")" "${row_files[@]}"
}

recreate_workloads() {
  local reason="$1"
  log "${reason}: recreating workload Pods to reset checkpoint/runtime state"
  bash "${REPO_ROOT}/scripts/19-deploy-shared-gpu-interference-workloads.sh" \
    --model "${MODEL}" \
    --node "${WORKLOAD_NODE}" \
    --pod-count "${#PODS[@]}" \
    --group "${GROUP}" \
    --workload-kind "${WORKLOAD_KIND}" \
    --yes
  refresh_pods
  wait_for_steady_state
}

after_checkpoint_scenario() {
  local repeat_id="$1"
  local scenario="$2"
  capture_full_logs "repeat-${repeat_id}-${scenario}"
  if (( CHECKPOINT_COOLDOWN_SECONDS > 0 )); then
    log "Repeat ${repeat_id}/${REPEAT}: cooldown ${CHECKPOINT_COOLDOWN_SECONDS}s after ${scenario}"
    sleep "${CHECKPOINT_COOLDOWN_SECONDS}"
  fi
  if [[ "${RECREATE_BETWEEN_SCENARIOS}" == "true" ]]; then
    recreate_workloads "Repeat ${repeat_id}/${REPEAT} after ${scenario}"
  fi
}

capture_full_logs() {
  local label="$1"
  local pod
  for pod in "${PODS[@]}"; do
    kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${pod}" > "${RESULT_DIR}/logs-${label}-${pod}.txt" 2>&1 || true
  done
}

capture initial-pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -l "experiment.gpu-cr/group=${GROUP}" -o wide
capture initial-pods-yaml kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -l "experiment.gpu-cr/group=${GROUP}" -o yaml

for repeat_id in $(seq 1 "${REPEAT}"); do
  log "Repeat ${repeat_id}/${REPEAT}: no-checkpoint baseline"
  sample_for "${repeat_id}" "no_checkpoint" "baseline" "${BASELINE_SECONDS}"

  log "Repeat ${repeat_id}/${REPEAT}: solo checkpoint"
  sample_for "${repeat_id}" "solo" "baseline" "${BASELINE_SECONDS}"
  run_checkpoint_set "${repeat_id}" "solo" "parallel" "${PODS[0]}"
  sample_for "${repeat_id}" "solo" "post" "${POST_SECONDS}"
  after_checkpoint_scenario "${repeat_id}" "solo"

  if (( ${#PODS[@]} >= 3 )); then
    log "Repeat ${repeat_id}/${REPEAT}: sequential checkpoint"
    sample_for "${repeat_id}" "sequential" "baseline" "${BASELINE_SECONDS}"
    run_checkpoint_set "${repeat_id}" "sequential" "sequential" "${PODS[0]}" "${PODS[1]}" "${PODS[2]}"
    sample_for "${repeat_id}" "sequential" "post" "${POST_SECONDS}"
    after_checkpoint_scenario "${repeat_id}" "sequential"
  fi

  if (( ${#PODS[@]} >= 2 )); then
    log "Repeat ${repeat_id}/${REPEAT}: concurrent checkpoint with 2 Pods"
    sample_for "${repeat_id}" "concurrent2" "baseline" "${BASELINE_SECONDS}"
    run_checkpoint_set "${repeat_id}" "concurrent2" "parallel" "${PODS[0]}" "${PODS[1]}"
    sample_for "${repeat_id}" "concurrent2" "post" "${POST_SECONDS}"
    after_checkpoint_scenario "${repeat_id}" "concurrent2"
  fi

  if (( ${#PODS[@]} >= 3 )); then
    log "Repeat ${repeat_id}/${REPEAT}: concurrent checkpoint with 3 Pods"
    sample_for "${repeat_id}" "concurrent3" "baseline" "${BASELINE_SECONDS}"
    run_checkpoint_set "${repeat_id}" "concurrent3" "parallel" "${PODS[0]}" "${PODS[1]}" "${PODS[2]}"
    sample_for "${repeat_id}" "concurrent3" "post" "${POST_SECONDS}"
    after_checkpoint_scenario "${repeat_id}" "concurrent3"

    log "Repeat ${repeat_id}/${REPEAT}: staggered periodic checkpoint"
    sample_for "${repeat_id}" "staggered" "baseline" "${BASELINE_SECONDS}"
    run_checkpoint_set "${repeat_id}" "staggered" "staggered" "${PODS[0]}" "${PODS[1]}" "${PODS[2]}"
    sample_for "${repeat_id}" "staggered" "post" "${POST_SECONDS}"
    after_checkpoint_scenario "${repeat_id}" "staggered"
  fi

  capture_full_logs "repeat-${repeat_id}"

  if [[ "${RECREATE_BETWEEN_REPEATS}" == "true" && "${repeat_id}" -lt "${REPEAT}" ]]; then
    recreate_workloads "Repeat ${repeat_id}/${REPEAT}"
  fi
done

capture final-pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -l "experiment.gpu-cr/group=${GROUP}" -o wide
capture_full_logs "final"

python3 - "${RESULT_DIR}" "${BASELINE_SECONDS}" "${POST_SECONDS}" <<'PY'
import csv
import math
import pathlib
import re
import statistics
import sys

result = pathlib.Path(sys.argv[1])
baseline_seconds = float(sys.argv[2])
post_seconds = float(sys.argv[3])

def mean(xs):
    return statistics.fmean(xs) if xs else math.nan

def stdev(xs):
    return statistics.stdev(xs) if len(xs) > 1 else 0.0

def p95(xs):
    if not xs:
        return math.nan
    xs = sorted(xs)
    return xs[min(len(xs) - 1, math.ceil(len(xs) * 0.95) - 1)]

dur_rows = list(csv.DictReader((result / "checkpoint-durations.csv").open()))
make_rows = list(csv.DictReader((result / "checkpoint-makespan.csv").open()))

solo_durations = [
    float(r["duration_ms"]) for r in dur_rows
    if r["scenario"] == "solo" and r["status"] == "Completed"
]
solo_avg = mean(solo_durations)

by_scenario = {}
for row in dur_rows:
    if row["status"] != "Completed":
        continue
    by_scenario.setdefault(row["scenario"], []).append(float(row["duration_ms"]))

by_makespan = {}
for row in make_rows:
    if row["status"] != "Completed":
        continue
    by_makespan.setdefault(row["scenario"], []).append(float(row["makespan_ms"]))

log_records = {}
line_re = re.compile(r"ts=([0-9.]+).*pod=([^ ]+).*latency_s=([0-9.]+).*ips=([0-9.]+)")
for log in result.glob("logs-final-*.txt"):
    pod = log.name.removeprefix("logs-final-").removesuffix(".txt")
    records = []
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        m = line_re.search(line)
        if not m:
            continue
        records.append((float(m.group(1)), float(m.group(3)), float(m.group(4))))
    log_records[pod] = records

cei_rows = []
for row in make_rows:
    if row["status"] != "Completed":
        continue
    targets = set(row["target_pods"].split("+"))
    start = float(row["start_epoch"])
    end = float(row["end_epoch"])
    for pod, records in log_records.items():
        if pod in targets:
            continue
        before = [ips for ts, latency, ips in records if start - baseline_seconds <= ts < start]
        during = [ips for ts, latency, ips in records if start <= ts <= end]
        after = [ips for ts, latency, ips in records if end < ts <= end + post_seconds]
        base = mean(before)
        dur = mean(during)
        post = mean(after)
        cei = 1 - (dur / base) if base and not math.isnan(base) and not math.isnan(dur) else math.nan
        cei_rows.append({
            "repeat": row["repeat"],
            "scenario": row["scenario"],
            "sibling_pod": pod,
            "baseline_ips": base,
            "during_ips": dur,
            "post_ips": post,
            "cei": cei,
            "baseline_samples": len(before),
            "during_samples": len(during),
            "post_samples": len(after),
        })

with (result / "checkpoint-makespan-summary.csv").open("w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["scenario", "samples", "avg_makespan_ms", "stdev_makespan_ms", "p95_makespan_ms"])
    for scenario in sorted(by_makespan):
        xs = by_makespan[scenario]
        writer.writerow([scenario, len(xs), f"{mean(xs):.3f}", f"{stdev(xs):.3f}", f"{p95(xs):.3f}"])

with (result / "shared-gpu-interference-summary.csv").open("w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["scenario", "samples", "avg_duration_ms", "stdev_duration_ms", "p95_duration_ms", "cci_factor_vs_solo"])
    for scenario in sorted(by_scenario):
        xs = by_scenario[scenario]
        cci = mean(xs) / solo_avg if solo_avg and not math.isnan(solo_avg) else math.nan
        writer.writerow([scenario, len(xs), f"{mean(xs):.3f}", f"{stdev(xs):.3f}", f"{p95(xs):.3f}", f"{cci:.3f}"])

with (result / "cei-summary.csv").open("w", newline="") as f:
    fieldnames = [
        "repeat", "scenario", "sibling_pod", "baseline_ips", "during_ips", "post_ips",
        "cei", "baseline_samples", "during_samples", "post_samples"
    ]
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for r in cei_rows:
        writer.writerow({
            **r,
            "baseline_ips": f"{r['baseline_ips']:.6f}" if not math.isnan(r["baseline_ips"]) else "",
            "during_ips": f"{r['during_ips']:.6f}" if not math.isnan(r["during_ips"]) else "",
            "post_ips": f"{r['post_ips']:.6f}" if not math.isnan(r["post_ips"]) else "",
            "cei": f"{r['cei']:.6f}" if not math.isnan(r["cei"]) else "",
        })

with (result / "summary.md").open("w", encoding="utf-8") as f:
    f.write("# Shared GPU Checkpoint Interference Benchmark\n\n")
    f.write("## Checkpoint-to-Checkpoint Interference\n\n")
    f.write("| scenario | samples | avg duration ms | stdev ms | p95 ms | CCI factor vs solo |\n")
    f.write("|---|---:|---:|---:|---:|---:|\n")
    for scenario in sorted(by_scenario):
        xs = by_scenario[scenario]
        cci = mean(xs) / solo_avg if solo_avg and not math.isnan(solo_avg) else math.nan
        f.write(f"| {scenario} | {len(xs)} | {mean(xs):.3f} | {stdev(xs):.3f} | {p95(xs):.3f} | {cci:.3f} |\n")
    f.write("\n## Checkpoint Makespan\n\n")
    f.write("| scenario | samples | avg makespan ms | stdev ms | p95 ms |\n")
    f.write("|---|---:|---:|---:|---:|\n")
    for scenario in sorted(by_makespan):
        xs = by_makespan[scenario]
        f.write(f"| {scenario} | {len(xs)} | {mean(xs):.3f} | {stdev(xs):.3f} | {p95(xs):.3f} |\n")
    f.write("\n## Checkpoint-to-Execution Interference\n\n")
    f.write("| repeat | scenario | sibling pod | baseline ips | during ips | post ips | CEI |\n")
    f.write("|---:|---|---|---:|---:|---:|---:|\n")
    for r in cei_rows:
        if math.isnan(r["cei"]):
            f.write(f"| {r['repeat']} | {r['scenario']} | {r['sibling_pod']} |  |  |  |  |\n")
        else:
            f.write(
                f"| {r['repeat']} | {r['scenario']} | {r['sibling_pod']} | "
                f"{r['baseline_ips']:.6f} | {r['during_ips']:.6f} | {r['post_ips']:.6f} | {r['cei']:.6f} |\n"
            )
    f.write("\n## Raw Evidence\n\n")
    for name in [
        "checkpoint-durations.csv",
        "checkpoint-makespan.csv",
        "checkpoint-makespan-summary.csv",
        "shared-gpu-interference-summary.csv",
        "cei-summary.csv",
        "node-resource-samples.csv",
        "pod-resource-samples.csv",
        "gpu-samples.csv",
        "logs-final-*.txt",
    ]:
        f.write(f"- `{name}`\n")
    f.write("\n## Notes\n\n")
    f.write("- CCI factor는 concurrent/sequential/staggered 개별 checkpoint 평균 시간을 solo checkpoint 평균 시간으로 나눈 내부 비교값이다.\n")
    f.write("- Makespan은 같은 scenario에서 첫 checkpoint 시작부터 마지막 checkpoint 완료까지의 전체 evacuation 시간이다.\n")
    f.write("- CEI는 checkpoint window 동안 sibling Pod의 ips가 baseline 대비 얼마나 감소했는지 계산한 값이다.\n")
    f.write("- CCI/CEI 임계값은 보편 기준이 아니라 실험 해석을 돕는 heuristic이다.\n")

print(f"Wrote {result / 'summary.md'}")
PY

write_state "last-shared-gpu-interference-result-dir" "${RESULT_DIR}"
log "Shared-GPU checkpoint interference benchmark completed. Result: ${RESULT_DIR}"
