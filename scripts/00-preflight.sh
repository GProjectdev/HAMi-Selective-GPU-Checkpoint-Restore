#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/kubernetes.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir preflight
require_cmd git
require_cmd awk
require_kubectl
assert_not_home_git_root

capture current-context kubectl config current-context
capture nodes kubectl get nodes -o wide
capture pods-all kubectl get pods -A -o wide
capture gpu-nodes bash -c "kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}{end}'"

source_node="$(detect_source_node || true)"
target_node="$(detect_target_node || true)"
[[ -n "${source_node}" ]] || die "No GPU source node detected. Set SOURCE_NODE in config/experiment.env."
log "Detected source node: ${source_node}"
log "Detected target node: ${target_node:-UNKNOWN}"
append_summary "# Preflight" "" "- source node: ${source_node}" "- target node: ${target_node:-UNKNOWN}"

