#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir baseline
require_kubectl

capture pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -o wide
capture pod-a-log kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-a --tail=200
capture pod-b-log kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=200
capture pod-a-gpu kubectl -n "${EXPERIMENT_NAMESPACE}" exec hami-pod-a -- nvidia-smi
capture pod-b-gpu kubectl -n "${EXPERIMENT_NAMESPACE}" exec hami-pod-b -- nvidia-smi
append_summary "# Baseline" "" "- Pod A and Pod B logs plus nvidia-smi snapshots captured."

