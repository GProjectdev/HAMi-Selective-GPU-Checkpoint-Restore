#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/kubernetes.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir cross-node-restore
die "Cross-node restore is intentionally not implemented in this same-worker experiment. Use same-node restore first, then add nfs:// or http(s):// checkpoint-uri support for migration."
