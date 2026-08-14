#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir selective-gcr-criu
require_kubectl
require_cmd envsubst
confirm_destructive "Creating WorkloadCheckpoint for Pod A"

[[ -n "${SHARED_CHECKPOINT_ROOT:-}" ]] || die "Set SHARED_CHECKPOINT_ROOT."

if ! kubectl api-resources --no-headers 2>/dev/null | awk '$NF == "WorkloadCheckpoint" {found=1} END {exit !found}'; then
  kubectl api-resources > "${RESULT_DIR}/api-resources.txt" 2>&1 || true
  kubectl get crd > "${RESULT_DIR}/crds.txt" 2>&1 || true
  die "WorkloadCheckpoint CRD is not installed or uses a different Kind/apiVersion. Inspect ${RESULT_DIR}/api-resources.txt and ${RESULT_DIR}/crds.txt, install the base GPU C/R CRDs/operator, then update manifests/checkpoint-resources.yaml if the real apiVersion differs."
fi

if ! kubectl api-resources --no-headers 2>/dev/null | awk '$NF == "WorkloadRestore" {found=1} END {exit !found}'; then
  kubectl api-resources > "${RESULT_DIR}/api-resources.txt" 2>&1 || true
  kubectl get crd > "${RESULT_DIR}/crds.txt" 2>&1 || true
  die "WorkloadRestore CRD is not installed or uses a different Kind/apiVersion. Inspect ${RESULT_DIR}/api-resources.txt and ${RESULT_DIR}/crds.txt, install the base GPU C/R CRDs/operator, then update manifests/checkpoint-resources.yaml if the real apiVersion differs."
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  envsubst < "${REPO_ROOT}/manifests/checkpoint-resources.yaml" | kubectl apply --dry-run=server -f -
else
  envsubst < "${REPO_ROOT}/manifests/checkpoint-resources.yaml" | kubectl apply -f -
fi
capture pod-b-before kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=100
capture checkpoint-objects kubectl -n "${EXPERIMENT_NAMESPACE}" get workloadcheckpoint,workloadrestore -o yaml
capture pod-b-after kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=100
append_summary "# Selective C/R" "" "- Pod A checkpoint object submitted." "- Pod B before/after logs captured."
