#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/kubernetes.sh"

parse_common_args "$@"
load_env
init_result_dir install-hami
require_cmd helm
require_kubectl
confirm_destructive "Installing or upgrading HAMi in kube-system"

repo="${HAMI_HELM_REPOSITORY:-https://project-hami.github.io/HAMi/}"
chart="${HAMI_HELM_CHART:-hami-charts/hami}"
source_node="$(detect_source_node)"
[[ -n "${source_node}" ]] || die "Set SOURCE_NODE or ensure a GPU node exists."

run_cmd kubectl label node "${source_node}" gpu=on --overwrite
target_node="$(detect_target_node || true)"
if [[ -n "${target_node}" ]]; then
  run_cmd kubectl label node "${target_node}" gpu=on --overwrite
fi

run_cmd helm repo add hami-charts "${repo}" --force-update
run_cmd helm repo update
if [[ -n "${HAMI_VERSION:-}" ]]; then
  run_cmd helm upgrade --install hami "${chart}" -n kube-system --version "${HAMI_VERSION}"
else
  run_cmd helm upgrade --install hami "${chart}" -n kube-system
fi

