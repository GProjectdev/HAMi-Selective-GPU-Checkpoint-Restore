#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

parse_common_args "$@"
load_env
init_result_dir clean
require_kubectl
confirm_destructive "Deleting experiment namespace only"
run_cmd kubectl delete namespace "${EXPERIMENT_NAMESPACE}" --ignore-not-found=true

