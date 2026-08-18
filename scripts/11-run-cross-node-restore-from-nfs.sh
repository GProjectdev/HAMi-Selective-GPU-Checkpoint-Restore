#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir cross-node-restore-from-nfs
require_kubectl
require_cmd envsubst
confirm_destructive "Deleting source Pod A and restoring it on the cross-node target from NFS artifacts"

NFS_SERVER="${NFS_SERVER:-10.178.0.14}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-/mnt/nfs}"
HELPER_IMAGE="${CROSS_NODE_HELPER_IMAGE:-${WORKLOAD_BASE_IMAGE}}"

state_dir="${REPO_ROOT}/${STATE_ROOT#./}"
source_node="$(cat "${state_dir}/cross-node-source-node" 2>/dev/null || cat "${state_dir}/last-checkpoint-observed-node" 2>/dev/null || true)"
TARGET_NODE="${TARGET_NODE:-$(cat "${state_dir}/cross-node-target-node" 2>/dev/null || true)}"
nfs_run_dir="$(cat "${state_dir}/cross-node-nfs-run-dir" 2>/dev/null || true)"
source_pod_uid="$(cat "${state_dir}/last-checkpoint-source-pod-uid" 2>/dev/null || true)"
nfs_checkpoint_path="$(cat "${state_dir}/cross-node-nfs-checkpoint-path" 2>/dev/null || true)"
nfs_data_path="$(cat "${state_dir}/cross-node-nfs-data-path" 2>/dev/null || true)"

[[ -n "${source_node}" ]] || die "Missing source node. Run scripts/08-run-gcr-criu-selective-test.sh --yes and scripts/10-prepare-cross-node-nfs-artifacts.sh --yes first."
[[ -n "${TARGET_NODE}" ]] || die "Missing target node. Set TARGET_NODE or run scripts/10-prepare-cross-node-nfs-artifacts.sh --yes first."
[[ -n "${nfs_run_dir}" ]] || die "Missing NFS run directory. Run scripts/10-prepare-cross-node-nfs-artifacts.sh --yes first."
[[ -n "${source_pod_uid}" ]] || die "Missing source Pod UID. Run scripts/08-run-gcr-criu-selective-test.sh --yes first."
[[ -n "${nfs_checkpoint_path}" ]] || die "Missing NFS checkpoint path. Run scripts/10-prepare-cross-node-nfs-artifacts.sh --yes first."
[[ -n "${nfs_data_path}" ]] || die "Missing NFS data path. Run scripts/10-prepare-cross-node-nfs-artifacts.sh --yes first."
[[ "${TARGET_NODE}" != "${source_node}" ]] || die "TARGET_NODE must differ from source node for cross-node restore."

target_register="$(kubectl get node "${TARGET_NODE}" -o jsonpath='{.metadata.annotations.hami\.io/node-nvidia-register}' 2>/dev/null || true)"
RESTORE_GPU_UUID="${RESTORE_GPU_UUID:-$(grep -o 'GPU-[^",}]*' <<<"${target_register}" | head -1)}"
[[ -n "${RESTORE_GPU_UUID}" ]] || die "Could not find target HAMi GPU UUID from ${TARGET_NODE} hami.io/node-nvidia-register annotation."

tar_name="$(basename "${nfs_checkpoint_path}")"
blob_name="$(basename "${nfs_data_path}")"
RESTORE_CHECKPOINT_URI="${RESTORE_CHECKPOINT_URI:-nfs://${NFS_SERVER}${nfs_checkpoint_path}}"
RESTORE_DATA_URI="${RESTORE_DATA_URI:-nfs://${NFS_SERVER}${nfs_data_path}}"
RESTORE_SOURCE_POD_UID="${RESTORE_SOURCE_POD_UID:-${source_pod_uid}}"
RESTORE_BLOB_MODE="${RESTORE_BLOB_MODE:-copy}"

RESTORE_HAMI_VGPU_LOCK_SOURCE="${RESTORE_HAMI_VGPU_LOCK_SOURCE:-/tmp/vgpulock}"
RESTORE_HAMI_LD_PRELOAD_SOURCE="${RESTORE_HAMI_LD_PRELOAD_SOURCE:-/usr/local/vgpu/ld.so.preload}"
RESTORE_HAMI_ORIGINAL_VGPU_DIR_SOURCE="${RESTORE_HAMI_ORIGINAL_VGPU_DIR_SOURCE:-/usr/local/vgpu/containers/${RESTORE_SOURCE_POD_UID}_selective-target}"
RESTORE_HAMI_VGPU_DIR_SOURCE="${RESTORE_HAMI_VGPU_DIR_SOURCE:-/usr/local/vgpu/restore-cache/${RESTORE_SOURCE_POD_UID}_selective-target}"
RESTORE_HAMI_LIBVGPU_SOURCE="${RESTORE_HAMI_LIBVGPU_SOURCE:-/usr/local/vgpu/libvgpu.so.v2.9.0}"

export TARGET_NODE RESTORE_GPU_UUID RESTORE_CHECKPOINT_URI RESTORE_DATA_URI RESTORE_SOURCE_POD_UID RESTORE_BLOB_MODE
export RESTORE_HAMI_VGPU_LOCK_SOURCE RESTORE_HAMI_LD_PRELOAD_SOURCE RESTORE_HAMI_VGPU_DIR_SOURCE RESTORE_HAMI_LIBVGPU_SOURCE

source_cache_pod="hami-cross-cache-src-$(date -u '+%H%M%S')"
target_cache_pod="hami-cross-cache-dst-$(date -u '+%H%M%S')"

cleanup_helpers() {
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${source_cache_pod}" "${target_cache_pod}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}
trap cleanup_helpers EXIT

log "Source node: ${source_node}"
log "Target node: ${TARGET_NODE}"
log "Target HAMi GPU UUID: ${RESTORE_GPU_UUID}"
log "Restore checkpoint URI: ${RESTORE_CHECKPOINT_URI}"
log "Restore data URI: ${RESTORE_DATA_URI}"

stage_hami_cache_to_nfs() {
  log "Copying source HAMi runtime cache to NFS: ${RESTORE_HAMI_ORIGINAL_VGPU_DIR_SOURCE}"
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${source_cache_pod}" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${source_cache_pod}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app.kubernetes.io/name: hami-selective-cr
    experiment.gpu-cr/role: cross-node-source-cache
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${source_node}
  containers:
    - name: cache
      image: ${HELPER_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-lc"]
      args:
        - |
          set -Eeuo pipefail
          src="/host${RESTORE_HAMI_ORIGINAL_VGPU_DIR_SOURCE}"
          dst="/nfs/${nfs_run_dir}/hami-vgpu-cache"
          test -d "\${src}" || { echo "missing source HAMi runtime dir: \${src}" >&2; exit 20; }
          rm -rf "\${dst}.tmp"
          mkdir -p "\$(dirname "\${dst}")"
          cp -a "\${src}" "\${dst}.tmp"
          rm -rf "\${dst}"
          mv "\${dst}.tmp" "\${dst}"
          find "\${dst}" -maxdepth 2 -type f -name '*.cache' -exec chmod 0666 {} +
          find "\${dst}" -maxdepth 2 -ls
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
  kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${source_cache_pod}" --timeout=180s
  capture source-hami-cache-pod kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod "${source_cache_pod}"
  capture source-hami-cache-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${source_cache_pod}" --tail=200
}

install_hami_cache_on_target() {
  log "Installing HAMi runtime cache on target: ${RESTORE_HAMI_VGPU_DIR_SOURCE}"
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${target_cache_pod}" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${target_cache_pod}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app.kubernetes.io/name: hami-selective-cr
    experiment.gpu-cr/role: cross-node-target-cache
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${TARGET_NODE}
  containers:
    - name: cache
      image: ${HELPER_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-lc"]
      args:
        - |
          set -Eeuo pipefail
          src="/nfs/${nfs_run_dir}/hami-vgpu-cache"
          dst="/host${RESTORE_HAMI_VGPU_DIR_SOURCE}"
          test -d "\${src}" || { echo "missing NFS HAMi runtime cache: \${src}" >&2; exit 21; }
          mkdir -p /host/tmp/vgpulock
          test -f "/host${RESTORE_HAMI_LD_PRELOAD_SOURCE}" || { echo "missing target HAMi ld preload: /host${RESTORE_HAMI_LD_PRELOAD_SOURCE}" >&2; exit 22; }
          test -f "/host${RESTORE_HAMI_LIBVGPU_SOURCE}" || { echo "missing target HAMi libvgpu: /host${RESTORE_HAMI_LIBVGPU_SOURCE}" >&2; exit 23; }
          rm -rf "\${dst}.tmp"
          mkdir -p "\$(dirname "\${dst}")"
          cp -a "\${src}" "\${dst}.tmp"
          find "\${dst}.tmp" -maxdepth 2 -type f -name '*.cache' -exec chmod 0666 {} +
          rm -rf "\${dst}"
          mv "\${dst}.tmp" "\${dst}"
          find "\${dst}" -maxdepth 2 -ls
      securityContext:
        privileged: true
      volumeMounts:
        - name: host-root
          mountPath: /host
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
  kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${target_cache_pod}" --timeout=180s
  capture target-hami-cache-pod kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod "${target_cache_pod}"
  capture target-hami-cache-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${target_cache_pod}" --tail=200
}

if [[ "${DRY_RUN}" != "true" ]]; then
  stage_hami_cache_to_nfs
  install_hami_cache_on_target
fi

capture restore-manifest bash -lc "envsubst < '${REPO_ROOT}/manifests/restore-pod.yaml'"

run_cmd kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod hami-pod-a --ignore-not-found=true
run_cmd kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod hami-pod-a-restored --ignore-not-found=true
if [[ "${DRY_RUN}" == "true" ]]; then
  envsubst < "${REPO_ROOT}/manifests/restore-pod.yaml" | kubectl apply --dry-run=server -f -
else
  envsubst < "${REPO_ROOT}/manifests/restore-pod.yaml" | kubectl apply -f -
  kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready pod/hami-pod-a-restored --timeout="${RESTORE_TIMEOUT_SECONDS:-300}s"
fi

capture pods kubectl -n "${EXPERIMENT_NAMESPACE}" get pods -o wide
capture restored-pod kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod hami-pod-a-restored
capture restored-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-a-restored --tail=300
capture pod-b-after-cross-restore kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=200

write_state cross-node-restore-checkpoint-uri "${RESTORE_CHECKPOINT_URI}"
write_state cross-node-restore-data-uri "${RESTORE_DATA_URI}"
write_state cross-node-restore-target-gpu-uuid "${RESTORE_GPU_UUID}"

append_summary "# Cross Node Restore From NFS" "" \
  "- restore pod: hami-pod-a-restored" \
  "- source-node: ${source_node}" \
  "- target-node: ${TARGET_NODE}" \
  "- checkpoint-uri: ${RESTORE_CHECKPOINT_URI}" \
  "- data-uri: ${RESTORE_DATA_URI}" \
  "- source-pod-uid: ${RESTORE_SOURCE_POD_UID}" \
  "- target-hami-gpu-uuid: ${RESTORE_GPU_UUID}" \
  "- HAMi runtime cache copied source -> NFS -> target restore-cache."

log "Cross-node restore completed. Result: ${RESULT_DIR}"
