#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/kubernetes.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir cross-node-restore
require_kubectl
require_cmd envsubst
confirm_destructive "Submitting restore with target node"

target="$(detect_target_node || true)"
[[ -n "${target}" ]] || die "No target GPU node detected. Set TARGET_NODE."
log "Target node: ${target}"
export TARGET_NODE="${target}"
if [[ "${DRY_RUN}" == "true" ]]; then
  envsubst < "${REPO_ROOT}/manifests/checkpoint-resources.yaml" | kubectl apply --dry-run=server -f -
else
  envsubst < "${REPO_ROOT}/manifests/checkpoint-resources.yaml" | kubectl apply -f -
fi
capture pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -o wide
capture restore kubectl -n "${EXPERIMENT_NAMESPACE}" get workloadrestore -o yaml
