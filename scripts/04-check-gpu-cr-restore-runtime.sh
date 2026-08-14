#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir check-gpu-cr-restore-runtime
require_kubectl

RESTORE_CR_REPO="${RESTORE_CR_REPO:-../K8s-Native-GPU-Restore-CRI-O}"
restore_path="${REPO_ROOT}/${RESTORE_CR_REPO}"

capture nodes kubectl get nodes -o wide
capture restore-api-resources kubectl api-resources
capture restore-crds kubectl get crd
capture gpu-cr-system kubectl -n "${GPU_CR_NAMESPACE:-gpu-cr-system}" get pods -o wide

missing=()
[[ -d "${restore_path}" ]] || missing+=("Restore repository not found at ${restore_path}")
[[ -f "${restore_path}/scripts/install-node.sh" ]] || missing+=("Restore node installer missing: ${restore_path}/scripts/install-node.sh")
[[ -f "${restore_path}/crio-patch/server/gpu_cr_restore.go" ]] || missing+=("CRI-O restore patch source missing under restore repo")

if [[ ${#missing[@]} -gt 0 ]]; then
  printf '%s\n' "${missing[@]}" > "${RESULT_DIR}/missing-restore-runtime-prereqs.txt"
  die "Restore runtime prerequisites are missing. See ${RESULT_DIR}/missing-restore-runtime-prereqs.txt"
fi

cat > "${RESULT_DIR}/node-restore-install-commands.md" <<EOF
# Restore Runtime Node Commands

Run these on every GPU worker node, not on the master shell:

\`\`\`bash
cd ${restore_path}
sudo bash hack/build-crio.sh
sudo bash scripts/install-node.sh
systemctl is-active crio
systemctl is-active gpu-cr-restore-agent.service
\`\`\`

The restore path is node-local. This script cannot prove the CRI-O binary was patched
from Kubernetes alone; if stage 09 fails, inspect \`journalctl -u crio\` and
\`journalctl -u gpu-cr-restore-agent.service\` on the target worker.
EOF

append_summary "# GPU C/R Restore Runtime Check" "" "- Restore repository found: ${restore_path}" "- Node install commands written to ${RESULT_DIR}/node-restore-install-commands.md" "- Kubernetes-only checks captured. CRI-O patch/hook/agent must be verified on each worker node."
log "Restore runtime command guide: ${RESULT_DIR}/node-restore-install-commands.md"
