#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir verify-hami
require_kubectl

capture hami-pods kubectl -n kube-system get pods -o wide
capture hami-resources kubectl -n kube-system get deploy,ds,svc,cm -o wide
capture node-allocatable kubectl get nodes -o json
kubectl -n kube-system get pods | grep -Ei 'hami|vgpu' || die "HAMi pods not found in kube-system."
log "HAMi verification data captured."

