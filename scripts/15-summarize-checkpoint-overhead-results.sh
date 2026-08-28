#!/usr/bin/env bash
set -Eeuo pipefail

RESULT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --result-dir)
      shift
      RESULT_DIR="${1:?missing result directory}"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "${RESULT_DIR}" ]]; then
  if [[ -f ".state/last-checkpoint-overhead-result-dir" ]]; then
    RESULT_DIR="$(cat .state/last-checkpoint-overhead-result-dir)"
  else
    echo "Set --result-dir or run scripts/14-run-checkpoint-overhead-benchmark.sh first." >&2
    exit 1
  fi
fi

if [[ ! -d "${RESULT_DIR}" ]]; then
  echo "Result directory not found: ${RESULT_DIR}" >&2
  exit 1
fi

OUT_CSV="${RESULT_DIR}/overhead-summary.csv"
OUT_MD="${RESULT_DIR}/overhead-summary.md"
TMP="${RESULT_DIR}/.overhead-summary.tmp"

rm -f "${TMP}"

summarize_csv() {
  local file="$1"
  local metric_prefix="$2"
  local scope_cols="$3"
  local value_cols="$4"

  [[ -f "${file}" ]] || return 0

  awk -F',' -v metric_prefix="${metric_prefix}" -v scope_cols="${scope_cols}" -v value_cols="${value_cols}" '
    function trim(v) {
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      return v
    }
    function csv_escape(v) {
      gsub(/"/, "\"\"", v)
      return "\"" v "\""
    }
    function unit_name(header, raw) {
      if (header ~ /cpu$/ || header == "cpu") return "mCPU"
      if (header ~ /memory$/ || header == "memory") return "MiB"
      if (header ~ /percent$/ || header ~ /util_percent$/) return "%"
      if (header ~ /power_w$/) return "W"
      if (header ~ /gpu_mem_.*_mb$/) return "MiB"
      if (header ~ /duration_ms$/) return "ms"
      return ""
    }
    function numeric(v, header, lower, n) {
      v = trim(v)
      lower = v
      gsub(/[A-Z]/, "", lower)
      if (v == "" || v == "unavailable" || v == "nvidia-smi-unavailable") return ""
      gsub(/%/, "", v)
      if (v ~ /m$/) {
        sub(/m$/, "", v)
        return v + 0
      }
      if (v ~ /Ki$/) {
        sub(/Ki$/, "", v)
        return (v + 0) / 1024
      }
      if (v ~ /Mi$/) {
        sub(/Mi$/, "", v)
        return v + 0
      }
      if (v ~ /Gi$/) {
        sub(/Gi$/, "", v)
        return (v + 0) * 1024
      }
      if (v ~ /Ti$/) {
        sub(/Ti$/, "", v)
        return (v + 0) * 1024 * 1024
      }
      if (v ~ /^[0-9.]+$/) {
        n = v + 0
        if (header == "cpu") return n * 1000
        return n
      }
      gsub(/[^0-9.]/, "", v)
      return v == "" ? "" : v + 0
    }
    BEGIN {
      scount = split(scope_cols, sidx, ",")
      vcount = split(value_cols, vidx, ",")
    }
    NR == 1 {
      for (i = 1; i <= NF; i++) header[i] = trim($i)
      next
    }
    {
      phase = trim($3)
      if (phase != "baseline" && phase != "checkpoint" && phase != "post") next

      scope = ""
      for (i = 1; i <= scount; i++) {
        idx = sidx[i] + 0
        if (scope != "") scope = scope "/"
        scope = scope trim($idx)
      }

      for (i = 1; i <= vcount; i++) {
        idx = vidx[i] + 0
        val = numeric($idx, header[idx])
        if (val == "") continue
        key = metric_prefix ":" header[idx] ":" scope ":" phase
        sum[key] += val
        count[key] += 1
        if (!(key in max) || val > max[key]) max[key] = val
        metric_seen[metric_prefix ":" header[idx] ":" scope] = 1
        units[metric_prefix ":" header[idx] ":" scope] = unit_name(header[idx], $idx)
      }
    }
    END {
      for (metric in metric_seen) {
        split(metric, parts, ":")
        name = parts[1] ":" parts[2]
        scope = parts[3]
        bkey = metric ":baseline"
        ckey = metric ":checkpoint"
        pkey = metric ":post"

        bavg = count[bkey] ? sum[bkey] / count[bkey] : ""
        cavg = count[ckey] ? sum[ckey] / count[ckey] : ""
        pavg = count[pkey] ? sum[pkey] / count[pkey] : ""
        bmax = count[bkey] ? max[bkey] : ""
        cmax = count[ckey] ? max[ckey] : ""
        pmax = count[pkey] ? max[pkey] : ""

        cd = (bavg != "" && cavg != "") ? cavg - bavg : ""
        pd = (bavg != "" && pavg != "") ? pavg - bavg : ""
        cdp = (bavg != "" && cavg != "" && bavg != 0) ? (cavg - bavg) * 100 / bavg : ""
        pdp = (bavg != "" && pavg != "" && bavg != 0) ? (pavg - bavg) * 100 / bavg : ""

        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", \
          csv_escape(name), csv_escape(scope), csv_escape(units[metric]), \
          count[bkey]+0, fmt(bavg), fmt(bmax), count[ckey]+0, fmt(cavg), fmt(cmax), fmt(cd), fmt(cdp), \
          count[pkey]+0, fmt(pavg), fmt(pd), fmt(pdp)
      }
    }
    function fmt(v) {
      if (v == "") return ""
      return sprintf("%.3f", v)
    }
  ' "${file}" >> "${TMP}"
}

{
  printf 'metric,scope,unit,baseline_samples,baseline_avg,baseline_max,checkpoint_samples,checkpoint_avg,checkpoint_max,checkpoint_delta_avg,checkpoint_delta_avg_percent,post_samples,post_avg,post_delta_avg,post_delta_avg_percent\n'
} > "${OUT_CSV}"

summarize_csv "${RESULT_DIR}/node-resource-samples.csv" "node" "4" "5,6,7,8"
summarize_csv "${RESULT_DIR}/pod-resource-samples.csv" "workload-pod" "4,5" "6,7"
summarize_csv "${RESULT_DIR}/control-resource-samples.csv" "control-pod" "4,5" "6,7"
summarize_csv "${RESULT_DIR}/gpu-samples.csv" "gpu" "5" "6,7,8,9,10"

if [[ -f "${TMP}" ]]; then
  sort "${TMP}" >> "${OUT_CSV}"
  rm -f "${TMP}"
fi

{
  printf '# Checkpoint Overhead Delta Summary\n\n'
  printf -- '- result directory: `%s`\n' "${RESULT_DIR}"
  if [[ -f "${RESULT_DIR}/checkpoint-durations.csv" ]]; then
    awk -F',' '
      NR > 1 && $2 ~ /^[0-9]+$/ {
        n += 1
        sum += $2
        if (n == 1 || $2 > max) max = $2
        if (n == 1 || $2 < min) min = $2
      }
      END {
        if (n > 0) {
          printf "- checkpoint duration avg: %.3f ms\n", sum / n
          printf "- checkpoint duration min/max: %.3f / %.3f ms\n", min, max
        }
      }
    ' "${RESULT_DIR}/checkpoint-durations.csv"
  fi
  printf '\n'
  printf '## Delta Table\n\n'
  printf '| metric | scope | unit | baseline avg | checkpoint avg | checkpoint delta | checkpoint delta %% | post avg | post delta | post delta %% |\n'
  printf '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n'
  awk -F',' '
    NR > 1 {
      printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
        unq($1), unq($2), unq($3), $5, $8, $10, $11, $13, $14, $15
    }
    function unq(v) {
      gsub(/^"|"$/, "", v)
      gsub(/""/, "\"", v)
      return v
    }
  ' "${OUT_CSV}"
  printf '\n'
  printf '## Notes\n\n'
  printf -- '- `checkpoint_delta_avg` = checkpoint 평균 - baseline 평균이다.\n'
  printf -- '- `post_delta_avg` = post 평균 - baseline 평균이다.\n'
  printf -- '- CPU 단위는 mCPU이고, memory/GPU memory 단위는 MiB이다.\n'
  printf -- '- `gpu-samples.csv`에 `nvidia-smi-unavailable` 행이 있으면 checkpoint 중 Pod 내부 GPU 샘플이 누락된 것이다. 이 경우 GPU checkpoint 구간의 정확한 순간 peak는 Worker Node host-level nvidia-smi 샘플러로 보강해야 한다.\n'
} > "${OUT_MD}"

echo "Wrote ${OUT_CSV}"
echo "Wrote ${OUT_MD}"
