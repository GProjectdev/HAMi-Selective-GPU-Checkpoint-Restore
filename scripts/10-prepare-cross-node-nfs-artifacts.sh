#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir cross-node-nfs-artifacts
require_kubectl
require_cmd awk
confirm_destructive "Staging the latest checkpoint artifacts to NFS and verifying target-node readability"

NFS_SERVER="${NFS_SERVER:-10.178.0.14}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-/mnt/nfs}"
NFS_ARTIFACT_SUBDIR="${NFS_ARTIFACT_SUBDIR:-gcr_lastmonth/hami-selective-cr}"
HELPER_IMAGE="${CROSS_NODE_HELPER_IMAGE:-${WORKLOAD_BASE_IMAGE}}"

state_dir="${REPO_ROOT}/${STATE_ROOT#./}"
checkpoint_path="$(cat "${state_dir}/last-checkpoint-path" 2>/dev/null || true)"
checkpoint_uri="$(cat "${state_dir}/last-checkpoint-uri" 2>/dev/null || true)"
data_uri="$(cat "${state_dir}/last-checkpoint-data-uri" 2>/dev/null || true)"
source_pod_uid="$(cat "${state_dir}/last-checkpoint-source-pod-uid" 2>/dev/null || true)"
source_node="$(cat "${state_dir}/last-checkpoint-observed-node" 2>/dev/null || true)"
hami_gpu_uuid="$(cat "${state_dir}/last-hami-gpu-uuid" 2>/dev/null || true)"
hami_cache_source="/usr/local/vgpu/containers/${source_pod_uid}_selective-target"

[[ -n "${checkpoint_path}" ]] || die "Missing .state/last-checkpoint-path. Run scripts/08-run-gcr-criu-selective-test.sh --yes first."
[[ -n "${source_pod_uid}" ]] || die "Missing .state/last-checkpoint-source-pod-uid. Run scripts/08-run-gcr-criu-selective-test.sh --yes first."
[[ -n "${source_node}" ]] || die "Missing .state/last-checkpoint-observed-node. Run scripts/08-run-gcr-criu-selective-test.sh --yes first."

if [[ -z "${TARGET_NODE:-}" || "${TARGET_NODE}" == "${source_node}" ]]; then
  TARGET_NODE="$(
    kubectl get nodes --no-headers 2>/dev/null |
      awk -v src="${source_node}" '$1 != src && $2 ~ /Ready/ && $0 !~ /(control-plane|master)/ {print $1; exit}'
  )"
fi
[[ -n "${TARGET_NODE}" ]] || die "TARGET_NODE is empty and no other Ready worker node was found. Set TARGET_NODE in config/experiment.env."
[[ "${TARGET_NODE}" != "${source_node}" ]] || die "TARGET_NODE must be different from source node for this cross-node readiness check."

run_id="$(date -u '+%Y%m%dT%H%M%SZ')"
nfs_run_dir="${NFS_ARTIFACT_SUBDIR%/}/${run_id}-${source_pod_uid}"
stage_pod="hami-cross-nfs-stage-${run_id,,}"
verify_pod="hami-cross-nfs-verify-${run_id,,}"

tar_name="$(basename "${checkpoint_path}")"
blob_name="$(basename "${checkpoint_path%.tar}.blob")"

cleanup_helper() {
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${stage_pod}" "${verify_pod}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}
trap cleanup_helper EXIT

log "Source node: ${source_node}"
log "Target node: ${TARGET_NODE}"
log "NFS export: ${NFS_SERVER}:${NFS_EXPORT_PATH}"
log "NFS artifact dir: ${nfs_run_dir}"

if [[ "${DRY_RUN}" == "true" ]]; then
  append_summary "# Cross Node NFS Artifact Readiness" "" "- DRY_RUN only." "- source-node: ${source_node}" "- target-node: ${TARGET_NODE}" "- nfs: ${NFS_SERVER}:${NFS_EXPORT_PATH}/${nfs_run_dir}"
  exit 0
fi

kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${stage_pod}" "${verify_pod}" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${stage_pod}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app.kubernetes.io/name: hami-selective-cr
    experiment.gpu-cr/role: cross-node-nfs-stage
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${source_node}
  containers:
    - name: stage
      image: ${HELPER_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-lc"]
      args:
        - |
          set -Eeuo pipefail
          src_tar="/host${checkpoint_path}"
          src_blob="/host${checkpoint_path%.tar}.blob"
          src_hami_cache="/host${hami_cache_source}"
          dst="/nfs/${nfs_run_dir}"
          test -f "\${src_tar}" || { echo "missing checkpoint tar: \${src_tar}" >&2; exit 10; }
          test -f "\${src_blob}" || { echo "missing checkpoint blob: \${src_blob}" >&2; exit 11; }
          test -d "\${src_hami_cache}" || { echo "missing source HAMi runtime dir: \${src_hami_cache}" >&2; exit 12; }
          mkdir -p "\${dst}"
          cp -a "\${src_tar}" "\${dst}/${tar_name}"
          cp -a "\${src_blob}" "\${dst}/${blob_name}"
          rm -rf "\${dst}/hami-vgpu-cache.tmp"
          cp -a "\${src_hami_cache}" "\${dst}/hami-vgpu-cache.tmp"
          find "\${dst}/hami-vgpu-cache.tmp" -maxdepth 2 -type f -name '*.cache' -exec chmod 0666 {} +
          rm -rf "\${dst}/hami-vgpu-cache"
          mv "\${dst}/hami-vgpu-cache.tmp" "\${dst}/hami-vgpu-cache"
          cd "\${dst}"
          sha256sum "${tar_name}" "${blob_name}" > SHA256SUMS
          {
            printf '%s\n' 'source_node=${source_node}'
            printf '%s\n' 'target_node=${TARGET_NODE}'
            printf '%s\n' 'source_pod_uid=${source_pod_uid}'
            printf '%s\n' 'checkpoint_uri=${checkpoint_uri}'
            printf '%s\n' 'data_uri=${data_uri}'
            printf '%s\n' 'hami_gpu_uuid=${hami_gpu_uuid}'
            printf '%s\n' 'nfs_server=${NFS_SERVER}'
            printf '%s\n' 'nfs_export_path=${NFS_EXPORT_PATH}'
            printf '%s\n' 'nfs_run_dir=${nfs_run_dir}'
            printf '%s\n' 'tar_name=${tar_name}'
            printf '%s\n' 'blob_name=${blob_name}'
            printf '%s\n' 'hami_cache_source=${hami_cache_source}'
          } > metadata.env
          ls -lh
          find hami-vgpu-cache -maxdepth 2 -ls
          cat SHA256SUMS
      securityContext:
        privileged: true
      volumeMounts:
        - name: host-root
          mountPath: /host
          readOnly: true
        - name: nfs-artifacts
          mountPath: /nfs
  volumes:
    - name: host-root
      hostPath:
        path: /
        type: Directory
    - name: nfs-artifacts
      nfs:
        server: ${NFS_SERVER}
        path: ${NFS_EXPORT_PATH}
YAML

kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${stage_pod}" --timeout=300s
capture nfs-stage-pod kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod "${stage_pod}"
capture nfs-stage-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${stage_pod}" --tail=200

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${verify_pod}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app.kubernetes.io/name: hami-selective-cr
    experiment.gpu-cr/role: cross-node-nfs-verify
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${TARGET_NODE}
  containers:
    - name: verify
      image: ${HELPER_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-lc"]
      args:
        - |
          set -Eeuo pipefail
          cd "/nfs/${nfs_run_dir}"
          sha256sum -c SHA256SUMS
          test -d hami-vgpu-cache || { echo "missing staged hami-vgpu-cache" >&2; exit 21; }
          ls -lh
          find hami-vgpu-cache -maxdepth 2 -ls
          cat metadata.env
      volumeMounts:
        - name: nfs-artifacts
          mountPath: /nfs
  volumes:
    - name: nfs-artifacts
      nfs:
        server: ${NFS_SERVER}
        path: ${NFS_EXPORT_PATH}
YAML

kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${verify_pod}" --timeout=300s
capture nfs-verify-pod kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod "${verify_pod}"
capture nfs-verify-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${verify_pod}" --tail=200

write_state cross-node-source-node "${source_node}"
write_state cross-node-target-node "${TARGET_NODE}"
write_state cross-node-nfs-server "${NFS_SERVER}"
write_state cross-node-nfs-export-path "${NFS_EXPORT_PATH}"
write_state cross-node-nfs-run-dir "${nfs_run_dir}"
write_state cross-node-nfs-checkpoint-path "${NFS_EXPORT_PATH%/}/${nfs_run_dir}/${tar_name}"
write_state cross-node-nfs-data-path "${NFS_EXPORT_PATH%/}/${nfs_run_dir}/${blob_name}"

append_summary "# Cross Node NFS Artifact Readiness" "" \
  "- source-node: ${source_node}" \
  "- target-node: ${TARGET_NODE}" \
  "- nfs-export: ${NFS_SERVER}:${NFS_EXPORT_PATH}" \
  "- nfs-run-dir: ${nfs_run_dir}" \
  "- checkpoint-file: ${tar_name}" \
  "- data-file: ${blob_name}" \
  "- hami-cache: hami-vgpu-cache" \
  "- target node verified SHA256SUMS successfully."

log "Cross-node NFS artifact readiness verified. Result: ${RESULT_DIR}"
