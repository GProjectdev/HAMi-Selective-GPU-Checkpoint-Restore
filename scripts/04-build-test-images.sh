#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

parse_common_args "$@"
load_env
init_result_dir build-images
require_cmd docker

[[ -n "${TARGET_IMAGE:-}" ]] || die "Set TARGET_IMAGE in config/experiment.env."
[[ -n "${CO_RUNNER_IMAGE:-}" ]] || die "Set CO_RUNNER_IMAGE in config/experiment.env."
run_cmd docker build -t "${TARGET_IMAGE}" "${REPO_ROOT}/workloads/selective-target"
run_cmd docker build -t "${CO_RUNNER_IMAGE}" "${REPO_ROOT}/workloads/co-runner"
if [[ -n "${IMAGE_REGISTRY:-}" ]]; then
  log "IMAGE_REGISTRY is set. Push images manually or extend this script after registry auth is configured."
fi

