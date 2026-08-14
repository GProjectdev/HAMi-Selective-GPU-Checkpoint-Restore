#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

parse_common_args "$@"
load_env
init_result_dir rollback
require_kubectl
confirm_destructive "Rolling back experiment resources and optional HAMi release"

run_cmd kubectl delete namespace "${EXPERIMENT_NAMESPACE}" --ignore-not-found=true
if helm -n kube-system status hami >/dev/null 2>&1; then
  run_cmd helm -n kube-system uninstall hami
fi
log "Rollback intentionally leaves Cilium, CoreDNS, control plane, nodes, and VMs untouched."

