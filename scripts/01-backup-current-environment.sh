#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir backup
require_kubectl
mkdir -p "${REPO_ROOT}/${BACKUP_ROOT#./}"

capture namespaces kubectl get namespaces -o yaml
capture nodes kubectl get nodes -o yaml
capture kube-system-pods kubectl -n kube-system get pods -o yaml
capture device-plugin kubectl -n kube-system get daemonset,deploy,cm -l app=nvidia-device-plugin -o yaml
capture hami-existing kubectl -n kube-system get all,cm,sa,role,rolebinding -l app.kubernetes.io/name=hami -o yaml
log "Backup completed. This script captures manifests only; it does not modify cluster state."

