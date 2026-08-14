#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir hami-pause-resume
require_kubectl

log "HAMi does not provide a generic per-pod GPU pause/resume API. Capturing scheduler and pod evidence for feasibility notes."
capture pod-a kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod hami-pod-a
capture pod-b kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod hami-pod-b
capture hami-logs kubectl -n kube-system logs -l app.kubernetes.io/name=hami --tail=300

