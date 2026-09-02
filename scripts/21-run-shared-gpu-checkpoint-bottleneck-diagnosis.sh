#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

MODEL=""
GROUP="shared-gpu-interference"
BASELINE_SECONDS=30
POST_SECONDS=30
SAMPLE_INTERVAL_SECONDS=1
CHECKPOINT_TIMEOUT_SECONDS="${RESTORE_TIMEOUT_SECONDS:-300}"
DIAG_IMAGE="${DIAG_IMAGE:-${WORKLOAD_BASE_IMAGE:-nvidia/cuda:12.4.1-devel-ubuntu22.04}}"
KEEP_DIAG_POD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) shift; MODEL="${1:?missing model}" ;;
    --group) shift; GROUP="${1:?missing group}" ;;
    --baseline-seconds) shift; BASELINE_SECONDS="${1:?missing seconds}" ;;
    --post-seconds) shift; POST_SECONDS="${1:?missing seconds}" ;;
    --sample-interval-seconds) shift; SAMPLE_INTERVAL_SECONDS="${1:?missing seconds}" ;;
    --checkpoint-timeout-seconds) shift; CHECKPOINT_TIMEOUT_SECONDS="${1:?missing seconds}" ;;
    --diag-image) shift; DIAG_IMAGE="${1:?missing image}" ;;
    --keep-diagnostic-pod) KEEP_DIAG_POD=true ;;
    --dry-run|--yes|-y|--env-file)
      break
      ;;
    *) die "Unknown argument before common args: $1" ;;
  esac
  shift
done

parse_common_args "$@"
load_env
init_result_dir "shared-gpu-checkpoint-bottleneck-${MODEL:-current}"
require_kubectl
confirm_destructive "Running shared-GPU checkpoint bottleneck diagnosis"
[[ "${DRY_RUN}" == "true" ]] && die "This diagnosis needs live sampling and cannot run with --dry-run."

GROUP="${GROUP:-$(cat "${REPO_ROOT}/${STATE_ROOT#./}/last-shared-gpu-interference-group" 2>/dev/null || true)}"
MODEL="${MODEL:-$(cat "${REPO_ROOT}/${STATE_ROOT#./}/last-shared-gpu-interference-model" 2>/dev/null || echo unknown)}"
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
  local pod node
  mapfile -t PODS < <(discover_pods_by_selector "experiment.gpu-cr/group=${GROUP}")
  if (( ${#PODS[@]} < 3 )); then
    mapfile -t PODS < <(
      discover_pods_by_selector "experiment.gpu-cr/role=shared-gpu-interference" |
        grep -E "^hami-interf-${MODEL_SAFE_NAME}-[a-z]+$" || true
    )
  fi
  (( ${#PODS[@]} >= 3 )) || die "Need at least three Running shared-GPU interference Pods for solo vs concurrent3 diagnosis."
  for pod in "${PODS[@]}"; do
    kubectl -n "${EXPERIMENT_NAMESPACE}" label pod "${pod}" "experiment.gpu-cr/group=${GROUP}" --overwrite >/dev/null 2>&1 || true
  done
  WORKLOAD_NODE="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${PODS[0]}" -o jsonpath='{.spec.nodeName}')"
  for pod in "${PODS[@]}"; do
    node="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
    [[ "${node}" == "${WORKLOAD_NODE}" ]] || die "Pods are not on the same node: ${PODS[0]}=${WORKLOAD_NODE}, ${pod}=${node}"
    kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready "pod/${pod}" --timeout=60s
  done
}

sanitize_name() {
  tr '[:upper:]_.' '[:lower:]--' <<<"$1" | tr -cd 'a-z0-9-' | cut -c1-240
}

DIAG_POD="hami-bottleneck-diag-$(date -u '+%H%M%S')"

cleanup() {
  local code=$?
  if [[ "${KEEP_DIAG_POD}" != "true" ]]; then
    kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${DIAG_POD}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  fi
  exit "${code}"
}
trap cleanup EXIT

refresh_pods

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${DIAG_POD}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app.kubernetes.io/name: hami-selective-cr
    experiment.gpu-cr/role: bottleneck-diagnostics
    experiment.gpu-cr/group: ${GROUP}
spec:
  restartPolicy: Never
  hostPID: true
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: ${WORKLOAD_NODE}
  tolerations:
    - operator: Exists
  containers:
    - name: diag
      image: ${DIAG_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: true
      command: ["/bin/bash", "-lc"]
      args: ["sleep 86400"]
      volumeMounts:
        - name: host-root
          mountPath: /host
          readOnly: true
  volumes:
    - name: host-root
      hostPath:
        path: /
        type: Directory
EOF

kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready "pod/${DIAG_POD}" --timeout=180s

host_exec() {
  kubectl -n "${EXPERIMENT_NAMESPACE}" exec "${DIAG_POD}" -- chroot /host /bin/bash -lc "$1"
}

capture_gpu_cr_node_agent_logs() {
  local scenario="$1"
  local out="${RESULT_DIR}/gpu-cr-node-agent-${scenario}.log"
  kubectl -n "${GPU_CR_NAMESPACE:-gpu-cr-system}" logs -l app=gpu-cr-node-agent --tail=400 > "${out}" 2>&1 || true
  if ! grep -qiE 'checkpoint|gpu-cr|gcr|criu|error|warn' "${out}" 2>/dev/null; then
    : > "${out}"
    while read -r pod_ref; do
      [[ -n "${pod_ref}" ]] || continue
      {
        printf '===== %s =====\n' "${pod_ref}"
        kubectl -n "${GPU_CR_NAMESPACE:-gpu-cr-system}" logs "${pod_ref#pod/}" --tail=400 2>&1 || true
      } >> "${out}"
    done < <(kubectl -n "${GPU_CR_NAMESPACE:-gpu-cr-system}" get pods -o name 2>/dev/null | grep 'gpu-cr-node-agent' || true)
  fi
}

capture initial-pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -l "experiment.gpu-cr/group=${GROUP}" -o wide
capture diagnostic-pod kubectl -n "${EXPERIMENT_NAMESPACE}" get pod "${DIAG_POD}" -o yaml
host_exec 'hostname; uname -a; uptime; free -m; df -h /var/lib/gcr-checkpoint /var/lib/gcr-data 2>/dev/null || true; command -v iostat || true; command -v pidstat || true; command -v nvidia-smi || true' > "${RESULT_DIR}/host-preflight.txt" 2>&1 || true

printf 'timestamp_epoch,timestamp_utc,scenario,phase,cpu_user,cpu_nice,cpu_system,cpu_idle,cpu_iowait,cpu_irq,cpu_softirq,mem_total_kb,mem_available_kb,dirty_kb,writeback_kb,load1,load5,load15,disk_read_sectors,disk_write_sectors,disk_weighted_io_ms\n' > "${RESULT_DIR}/host-resource-samples.csv"
printf 'timestamp_epoch,timestamp_utc,scenario,phase,gpu_timestamp,gpu_uuid,gpu_util_percent,mem_util_percent,gpu_mem_used_mb,gpu_mem_free_mb,power_w\n' > "${RESULT_DIR}/host-gpu-samples.csv"
printf 'timestamp_epoch,timestamp_utc,scenario,phase,pid,ppid,comm,cpu_percent,mem_percent,rss_kb,args\n' > "${RESULT_DIR}/host-process-samples.csv"
printf 'scenario,concurrency,target_pod,start_epoch,end_epoch,duration_ms,status,checkpoint_path,payload_bytes\n' > "${RESULT_DIR}/checkpoint-durations.csv"
printf 'scenario,concurrency,target_pods,start_epoch,end_epoch,makespan_ms,status,total_payload_bytes\n' > "${RESULT_DIR}/checkpoint-makespan.csv"

sample_host_once() {
  local scenario="$1"
  local phase="$2"
  local ts utc
  ts="$(date +%s.%N)"
  utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  host_exec "python3 - '${ts}' '${utc}' '${scenario}' '${phase}' <<'PY'
import pathlib
import sys

ts, utc, scenario, phase = sys.argv[1:5]
stat = pathlib.Path('/proc/stat').read_text().splitlines()[0].split()
cpu = stat[1:8]
mem = {}
for line in pathlib.Path('/proc/meminfo').read_text().splitlines():
    key, value = line.split(':', 1)
    if key in {'MemTotal', 'MemAvailable', 'Dirty', 'Writeback'}:
        mem[key] = value.strip().split()[0]
load = pathlib.Path('/proc/loadavg').read_text().split()[:3]
read_sectors = write_sectors = weighted_ms = 0
for line in pathlib.Path('/proc/diskstats').read_text().splitlines():
    parts = line.split()
    if len(parts) < 14:
        continue
    name = parts[2]
    if not (name.startswith('sd') and len(name) == 3 or name.startswith('vd') and len(name) == 3 or (name.startswith('nvme') and 'p' not in name)):
        continue
    read_sectors += int(parts[5])
    write_sectors += int(parts[9])
    weighted_ms += int(parts[13])
print(','.join([
    ts, utc, scenario, phase, *cpu,
    mem.get('MemTotal', ''), mem.get('MemAvailable', ''), mem.get('Dirty', ''), mem.get('Writeback', ''),
    *load, str(read_sectors), str(write_sectors), str(weighted_ms)
]))
PY" >> "${RESULT_DIR}/host-resource-samples.csv" 2>/dev/null || true

  {
    printf '%s,%s,%s,%s,' "${ts}" "${utc}" "${scenario}" "${phase}"
    host_exec "nvidia-smi --query-gpu=timestamp,uuid,utilization.gpu,utilization.memory,memory.used,memory.free,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 || printf nvidia-smi-unavailable"
    printf '\n'
  } >> "${RESULT_DIR}/host-gpu-samples.csv"

  host_exec "ps -eo pid,ppid,comm,%cpu,%mem,rss,args --no-headers | grep -Ei 'criu|criugpu|crio|gpu-cr|gcr|nvidia|conmon|runc|crun' | grep -v grep | sed 's/,/ /g'" 2>/dev/null |
    while read -r pid ppid comm cpu mem rss args; do
      [[ -n "${pid:-}" ]] || continue
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "${ts}" "${utc}" "${scenario}" "${phase}" "${pid}" "${ppid}" "${comm}" "${cpu}" "${mem}" "${rss}" "${args:-}" >> "${RESULT_DIR}/host-process-samples.csv"
    done
}

sample_for() {
  local scenario="$1"
  local phase="$2"
  local duration="$3"
  local end
  end=$((SECONDS + duration))
  while (( SECONDS < end )); do
    sample_host_once "${scenario}" "${phase}"
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
    experiment.gpu-cr/role: bottleneck-diagnosis-checkpoint
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
  local checkpoint_path="$1"
  [[ -n "${checkpoint_path}" ]] || { printf '0'; return; }
  host_exec "
    total=0
    for f in '${checkpoint_path}' '${checkpoint_path%.tar}.blob' '${checkpoint_path%.tar}.hami-runtime.tar'; do
      if [ -f \"\$f\" ]; then
        size=\$(stat -c %s \"\$f\" 2>/dev/null || echo 0)
        total=\$((total + size))
      fi
    done
    echo \"\$total\"
  " 2>/dev/null | tail -1
}

run_one_checkpoint() {
  local scenario="$1"
  local concurrency="$2"
  local pod="$3"
  local out="$4"
  local name start_epoch end_epoch start_ns end_ns duration_ms status checkpoint_path payload_bytes
  name="$(sanitize_name "diag-${scenario}-${pod}")"
  start_epoch="$(date +%s.%N)"
  start_ns="$(date +%s%N)"
  status="Completed"
  make_gpucheckpoint "${name}" "${pod}"
  if ! kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Completed "gpucheckpoint/${name}" --timeout="${CHECKPOINT_TIMEOUT_SECONDS}s" >/dev/null 2>&1; then
    status="Failed"
  fi
  end_ns="$(date +%s%N)"
  end_epoch="$(date +%s.%N)"
  duration_ms="$(( (end_ns - start_ns) / 1000000 ))"
  checkpoint_path="$(kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint "${name}" -o jsonpath='{.status.lastCheckpointPath}' 2>/dev/null || true)"
  payload_bytes="$(checkpoint_payload_bytes "${checkpoint_path}")"
  [[ "${payload_bytes}" =~ ^[0-9]+$ ]] || payload_bytes=0
  kubectl -n "${EXPERIMENT_NAMESPACE}" get gpucheckpoint "${name}" -o yaml > "${RESULT_DIR}/gpucheckpoint-${name}.yaml" 2>&1 || true
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "${scenario}" "${concurrency}" "${pod}" "${start_epoch}" "${end_epoch}" "${duration_ms}" "${status}" "${checkpoint_path}" "${payload_bytes}" > "${out}"
}

run_checkpoint_set() {
  local scenario="$1"
  shift
  local targets=("$@")
  local concurrency="${#targets[@]}"
  local pids=()
  local rows=()
  local start_epoch end_epoch start_ns end_ns row pod idx total status
  start_epoch="$(date +%s.%N)"
  start_ns="$(date +%s%N)"
  idx=0
  for pod in "${targets[@]}"; do
    row="${RESULT_DIR}/.checkpoint-${scenario}-${idx}.csv"
    rows+=("${row}")
    run_one_checkpoint "${scenario}" "${concurrency}" "${pod}" "${row}" &
    pids+=("$!")
    idx=$((idx + 1))
  done
  for pid in "${pids[@]}"; do
    wait "${pid}" || true
  done
  end_ns="$(date +%s%N)"
  end_epoch="$(date +%s.%N)"
  total=0
  status="Completed"
  for row in "${rows[@]}"; do
    cat "${row}" >> "${RESULT_DIR}/checkpoint-durations.csv"
    [[ "$(awk -F',' '{print $7}' "${row}")" == "Completed" ]] || status="Failed"
    total=$((total + $(awk -F',' '{print $9}' "${row}")))
  done
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "${scenario}" "${concurrency}" "$(IFS='+'; echo "${targets[*]}")" "${start_epoch}" "${end_epoch}" "$(( (end_ns - start_ns) / 1000000 ))" "${status}" "${total}" >> "${RESULT_DIR}/checkpoint-makespan.csv"
}

run_scenario() {
  local scenario="$1"
  shift
  local targets=("$@")
  log "Scenario ${scenario}: baseline ${BASELINE_SECONDS}s"
  sample_for "${scenario}" "baseline" "${BASELINE_SECONDS}"
  log "Scenario ${scenario}: checkpoint ${#targets[@]} Pod(s)"
  run_checkpoint_set "${scenario}" "${targets[@]}" &
  local ckpt_pid="$!"
  while kill -0 "${ckpt_pid}" >/dev/null 2>&1; do
    sample_host_once "${scenario}" "checkpoint"
    sleep "${SAMPLE_INTERVAL_SECONDS}"
  done
  wait "${ckpt_pid}" || true
  sample_host_once "${scenario}" "checkpoint"
  log "Scenario ${scenario}: post ${POST_SECONDS}s"
  sample_for "${scenario}" "post" "${POST_SECONDS}"
  host_exec "journalctl -u crio --since '-10 minutes' --no-pager 2>/dev/null | tail -400 || true" > "${RESULT_DIR}/journal-crio-${scenario}.log" 2>&1 || true
  capture_gpu_cr_node_agent_logs "${scenario}"
}

run_scenario "solo" "${PODS[0]}"
run_scenario "concurrent3" "${PODS[0]}" "${PODS[1]}" "${PODS[2]}"

python3 - "${RESULT_DIR}" <<'PY'
import csv
import math
import pathlib
import statistics
import sys

result = pathlib.Path(sys.argv[1])

def read_csv(name):
    with (result / name).open(newline="") as f:
        return list(csv.DictReader(f))

def mean(xs):
    return statistics.fmean(xs) if xs else math.nan

def pct(delta, base):
    return (delta / base * 100) if base else math.nan

def cpu_busy(row):
    idle = float(row["cpu_idle"]) + float(row["cpu_iowait"])
    total = sum(float(row[k]) for k in ["cpu_user", "cpu_nice", "cpu_system", "cpu_idle", "cpu_iowait", "cpu_irq", "cpu_softirq"])
    return total, idle

resources = read_csv("host-resource-samples.csv")
gpus = read_csv("host-gpu-samples.csv")
durations = read_csv("checkpoint-durations.csv")
makespans = read_csv("checkpoint-makespan.csv")

resource_summary = []
for scenario in sorted({r["scenario"] for r in resources}):
    rows = [r for r in resources if r["scenario"] == scenario]
    phases = {r["phase"] for r in rows}
    phase_rows = {p: [r for r in rows if r["phase"] == p] for p in phases}
    for phase, rs in sorted(phase_rows.items()):
        mem_avail = [float(r["mem_available_kb"]) / 1024 for r in rs if r["mem_available_kb"]]
        dirty = [float(r["dirty_kb"]) / 1024 for r in rs if r["dirty_kb"]]
        writeback = [float(r["writeback_kb"]) / 1024 for r in rs if r["writeback_kb"]]
        load1 = [float(r["load1"]) for r in rs if r["load1"]]
        resource_summary.append([scenario, phase, len(rs), mean(mem_avail), mean(dirty), mean(writeback), mean(load1)])

disk_summary = []
for scenario in sorted({r["scenario"] for r in resources}):
    ckpt = [r for r in resources if r["scenario"] == scenario and r["phase"] == "checkpoint"]
    if len(ckpt) < 2:
        continue
    first, last = ckpt[0], ckpt[-1]
    elapsed = float(last["timestamp_epoch"]) - float(first["timestamp_epoch"])
    written_mib = (float(last["disk_write_sectors"]) - float(first["disk_write_sectors"])) * 512 / (1024 * 1024)
    read_mib = (float(last["disk_read_sectors"]) - float(first["disk_read_sectors"])) * 512 / (1024 * 1024)
    weighted_delta = float(last["disk_weighted_io_ms"]) - float(first["disk_weighted_io_ms"])
    disk_summary.append([scenario, elapsed, read_mib, written_mib, written_mib / elapsed if elapsed > 0 else math.nan, weighted_delta])

gpu_summary = []
for scenario in sorted({r["scenario"] for r in gpus}):
    for phase in sorted({r["phase"] for r in gpus if r["scenario"] == scenario}):
        rows = [r for r in gpus if r["scenario"] == scenario and r["phase"] == phase and r["gpu_util_percent"] and r["gpu_util_percent"] != "nvidia-smi-unavailable"]
        util = [float(r["gpu_util_percent"].strip()) for r in rows]
        mem_util = [float(r["mem_util_percent"].strip()) for r in rows]
        power = [float(r["power_w"].strip()) for r in rows]
        gpu_summary.append([scenario, phase, len(rows), mean(util), mean(mem_util), mean(power)])

with (result / "bottleneck-resource-summary.csv").open("w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["scenario", "phase", "samples", "avg_mem_available_mib", "avg_dirty_mib", "avg_writeback_mib", "avg_load1"])
    w.writerows(resource_summary)

with (result / "bottleneck-disk-summary.csv").open("w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["scenario", "checkpoint_sample_span_s", "host_disk_read_mib_delta", "host_disk_write_mib_delta", "approx_write_mib_s", "weighted_io_ms_delta"])
    w.writerows(disk_summary)

with (result / "bottleneck-gpu-summary.csv").open("w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["scenario", "phase", "samples", "avg_gpu_util_percent", "avg_mem_util_percent", "avg_power_w"])
    w.writerows(gpu_summary)

solo_ms = [float(r["duration_ms"]) for r in durations if r["scenario"] == "solo" and r["status"] == "Completed"]
con_ms = [float(r["duration_ms"]) for r in durations if r["scenario"] == "concurrent3" and r["status"] == "Completed"]
solo_avg = mean(solo_ms)
con_avg = mean(con_ms)
cci = con_avg / solo_avg if solo_avg else math.nan

evidence = []
for row in disk_summary:
    scenario, elapsed, read_mib, written_mib, write_mib_s, weighted = row
    evidence.append(f"- {scenario}: checkpoint window disk write delta {written_mib:.1f} MiB, approx {write_mib_s:.1f} MiB/s, weighted_io_ms_delta {weighted:.0f}.")
for row in gpu_summary:
    scenario, phase, samples, util, mem_util, power = row
    if phase == "checkpoint":
        evidence.append(f"- {scenario}: checkpoint GPU util avg {util:.1f}%, memory util avg {mem_util:.1f}%, power avg {power:.1f} W.")

with (result / "summary.md").open("w", encoding="utf-8") as f:
    f.write("# Shared GPU Checkpoint Bottleneck Diagnosis\n\n")
    f.write("## Checkpoint Timing\n\n")
    f.write(f"- solo avg duration ms: {solo_avg:.3f}\n")
    f.write(f"- concurrent3 avg duration ms: {con_avg:.3f}\n")
    f.write(f"- concurrent3 CCI factor vs solo: {cci:.3f}\n\n")
    f.write("## Evidence Files\n\n")
    for name in [
        "checkpoint-durations.csv",
        "checkpoint-makespan.csv",
        "host-resource-samples.csv",
        "host-gpu-samples.csv",
        "host-process-samples.csv",
        "bottleneck-resource-summary.csv",
        "bottleneck-disk-summary.csv",
        "bottleneck-gpu-summary.csv",
        "journal-crio-*.log",
        "gpu-cr-node-agent-*.log",
    ]:
        f.write(f"- `{name}`\n")
    f.write("\n## Initial Interpretation\n\n")
    f.write("- If concurrent3 CCI is high and disk write delta/writeback/Dirty grows sharply, disk write path is a strong bottleneck candidate.\n")
    f.write("- If GPU memory util or GPU util changes sharply during checkpoint while disk pressure is mild, GPU copy/synchronization is a strong candidate.\n")
    f.write("- If process samples show criu/criugpu/crio/gpu-cr-node-agent CPU concentration or logs show serialized checkpoint operations, runtime serialization/lock contention is a strong candidate.\n")
    f.write("- If all host metrics remain mild but duration stretches, inspect gpu-cr-node-agent and CRIU logs for internal waits not visible in coarse host counters.\n\n")
    f.write("## Observed Signals\n\n")
    for line in evidence:
        f.write(line + "\n")

print(f"Wrote {result / 'summary.md'}")
PY

write_state "last-shared-gpu-bottleneck-result-dir" "${RESULT_DIR}"
log "Shared-GPU checkpoint bottleneck diagnosis completed. Result: ${RESULT_DIR}"
