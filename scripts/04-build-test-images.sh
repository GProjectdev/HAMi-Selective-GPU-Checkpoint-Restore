#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

parse_common_args "$@"
load_env
init_result_dir build-images
require_cmd docker

if [[ -z "${TARGET_IMAGE:-}" || -z "${CO_RUNNER_IMAGE:-}" ]]; then
  log "Custom workload images are not configured."
  log "Default deployment uses WORKLOAD_BASE_IMAGE plus ConfigMap-mounted CUDA source, so this step is optional."
  exit 0
fi

run_cmd docker build -t "${TARGET_IMAGE}" "${REPO_ROOT}/workloads/selective-target"
run_cmd docker build -t "${CO_RUNNER_IMAGE}" "${REPO_ROOT}/workloads/co-runner"
if [[ -n "${IMAGE_REGISTRY:-}" ]]; then
  log "IMAGE_REGISTRY is set. Push images manually or extend this script after registry auth is configured."
fi
