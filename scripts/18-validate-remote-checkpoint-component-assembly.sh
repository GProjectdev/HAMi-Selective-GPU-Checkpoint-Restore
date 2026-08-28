#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

RESTORE_CHECK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore-check) RESTORE_CHECK=true ;;
    --dry-run|--yes|-y|--env-file)
      break
      ;;
    *) die "Unknown argument before common args: $1" ;;
  esac
  shift
done

parse_common_args "$@"
load_env
init_result_dir remote-checkpoint-component-assembly
require_kubectl
require_cmd awk
confirm_destructive "Validating remote checkpoint component transfer, directory reconstruction, and tar rebuild"

NFS_SERVER="${NFS_SERVER:-10.178.0.14}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-/mnt/nfs}"
NFS_ARTIFACT_SUBDIR="${NFS_ARTIFACT_SUBDIR:-gcr_lastmonth/hami-selective-cr}"
HELPER_IMAGE="${CROSS_NODE_HELPER_IMAGE:-${WORKLOAD_BASE_IMAGE}}"

state_dir="${REPO_ROOT}/${STATE_ROOT#./}"
checkpoint_path="$(cat "${state_dir}/last-checkpoint-path" 2>/dev/null || true)"
source_pod_uid="$(cat "${state_dir}/last-checkpoint-source-pod-uid" 2>/dev/null || true)"
source_node="$(cat "${state_dir}/last-checkpoint-observed-node" 2>/dev/null || true)"
checkpoint_container="$(cat "${state_dir}/last-checkpoint-container" 2>/dev/null || echo selective-target)"
hami_gpu_uuid="$(cat "${state_dir}/last-hami-gpu-uuid" 2>/dev/null || true)"

[[ -n "${checkpoint_path}" ]] || die "Missing .state/last-checkpoint-path. Run a GPUCheckpoint first."
[[ -n "${source_pod_uid}" ]] || die "Missing .state/last-checkpoint-source-pod-uid. Run a GPUCheckpoint first."
[[ -n "${source_node}" ]] || die "Missing .state/last-checkpoint-observed-node. Run a GPUCheckpoint first."

if [[ -z "${TARGET_NODE:-}" ]]; then
  TARGET_NODE="$(
    kubectl get nodes --no-headers 2>/dev/null |
      awk -v src="${source_node}" '$1 != src && $2 ~ /Ready/ && $0 !~ /(control-plane|master)/ {print $1; exit}'
  )"
fi
[[ -n "${TARGET_NODE}" ]] || die "TARGET_NODE is empty and no other Ready worker node was found."

run_id="$(date -u '+%Y%m%dT%H%M%SZ')"
nfs_run_dir="${NFS_ARTIFACT_SUBDIR%/}/${run_id}-${source_pod_uid}-components"
stage_pod="hami-remote-components-src-${run_id,,}"
verify_pod="hami-remote-components-verify-${run_id,,}"
pack_pod="hami-remote-components-pack-${run_id,,}"

tar_name="$(basename "${checkpoint_path}")"
rebuilt_tar_name="rebuilt-${tar_name}"
blob_path="${checkpoint_path%.tar}.blob"
blob_name="$(basename "${blob_path}")"
hami_cache_source="/usr/local/vgpu/containers/${source_pod_uid}_${checkpoint_container}"

cleanup_helper() {
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${stage_pod}" "${verify_pod}" "${pack_pod}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}
trap cleanup_helper EXIT

log "Source node: ${source_node}"
log "Verification node: ${TARGET_NODE}"
log "NFS receiver storage: ${NFS_SERVER}:${NFS_EXPORT_PATH}/${nfs_run_dir}"
log "Checkpoint source tar is read locally but not copied as the transfer artifact: ${checkpoint_path}"

if [[ "${DRY_RUN}" == "true" ]]; then
  append_summary "# Remote Checkpoint Component Assembly" "" "- DRY_RUN only." "- source-node: ${source_node}" "- verification-node: ${TARGET_NODE}" "- nfs-dir: ${nfs_run_dir}"
  exit 0
fi

kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${stage_pod}" "${verify_pod}" "${pack_pod}" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${stage_pod}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app.kubernetes.io/name: hami-selective-cr
    experiment.gpu-cr/role: remote-component-stage
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
          src_blob="/host${blob_path}"
          src_hami_cache="/host${hami_cache_source}"
          dst="/nfs/${nfs_run_dir}"
          components="\${dst}/components"
          test -f "\${src_tar}" || { echo "missing checkpoint tar: \${src_tar}" >&2; exit 10; }
          test -f "\${src_blob}" || { echo "missing checkpoint blob: \${src_blob}" >&2; exit 11; }
          rm -rf "\${dst}.tmp"
          mkdir -p "\${dst}.tmp/components" "\${dst}.tmp/gcr-data"
          tar -xf "\${src_tar}" -C "\${dst}.tmp/components"
          cp -a "\${src_blob}" "\${dst}.tmp/gcr-data/${blob_name}"
          if [ -d "\${src_hami_cache}" ]; then
            cp -a "\${src_hami_cache}" "\${dst}.tmp/hami-vgpu-cache"
            find "\${dst}.tmp/hami-vgpu-cache" -maxdepth 2 -type f -name '*.cache' -exec chmod 0666 {} +
          else
            mkdir -p "\${dst}.tmp/hami-vgpu-cache"
            printf 'missing source HAMi runtime dir: %s\n' "\${src_hami_cache}" > "\${dst}.tmp/hami-vgpu-cache/MISSING.txt"
          fi
          cd "\${dst}.tmp"
          find components gcr-data hami-vgpu-cache -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
          find components gcr-data hami-vgpu-cache -type f -printf '%P\t%s\t%m\n' | sort > FILE_MANIFEST.tsv
          {
            printf '%s\n' 'source_node=${source_node}'
            printf '%s\n' 'verification_node=${TARGET_NODE}'
            printf '%s\n' 'source_pod_uid=${source_pod_uid}'
            printf '%s\n' 'hami_gpu_uuid=${hami_gpu_uuid}'
            printf '%s\n' 'nfs_server=${NFS_SERVER}'
            printf '%s\n' 'nfs_export_path=${NFS_EXPORT_PATH}'
            printf '%s\n' 'nfs_run_dir=${nfs_run_dir}'
            printf '%s\n' 'source_checkpoint_path=${checkpoint_path}'
            printf '%s\n' 'source_blob_path=${blob_path}'
            printf '%s\n' 'rebuilt_tar_name=${rebuilt_tar_name}'
            printf '%s\n' 'note=source tar was unpacked locally; transfer artifact is component directory, not source tar'
          } > metadata.env
          rm -rf "\${dst}"
          mv "\${dst}.tmp" "\${dst}"
          cd "\${dst}"
          printf 'component file count: '
          wc -l < FILE_MANIFEST.tsv
          du -sh components gcr-data hami-vgpu-cache .
          head -40 FILE_MANIFEST.tsv
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

kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${stage_pod}" --timeout=600s
capture component-stage-pod kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod "${stage_pod}"
capture component-stage-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${stage_pod}" --tail=250

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${verify_pod}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app.kubernetes.io/name: hami-selective-cr
    experiment.gpu-cr/role: remote-component-verify
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
          test -f components/spec.dump
          test -d components/checkpoint
          test -f gcr-data/${blob_name}
          printf 'verified component file count: '
          wc -l < FILE_MANIFEST.tsv
          du -sh components gcr-data hami-vgpu-cache .
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
capture component-verify-pod kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod "${verify_pod}"
capture component-verify-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${verify_pod}" --tail=250

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pack_pod}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app.kubernetes.io/name: hami-selective-cr
    experiment.gpu-cr/role: remote-component-pack
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${TARGET_NODE}
  containers:
    - name: pack
      image: ${HELPER_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-lc"]
      args:
        - |
          set -Eeuo pipefail
          cd "/nfs/${nfs_run_dir}"
          tar -C components -cf "${rebuilt_tar_name}" .
          sha256sum "${rebuilt_tar_name}" > REBUILT_TAR_SHA256SUM
          tar -tf "${rebuilt_tar_name}" | sort > REBUILT_TAR_CONTENTS.txt
          test -f REBUILT_TAR_CONTENTS.txt
          test -s REBUILT_TAR_SHA256SUM
          ls -lh "${rebuilt_tar_name}" REBUILT_TAR_SHA256SUM
          head -80 REBUILT_TAR_CONTENTS.txt
      volumeMounts:
        - name: nfs-artifacts
          mountPath: /nfs
  volumes:
    - name: nfs-artifacts
      nfs:
        server: ${NFS_SERVER}
        path: ${NFS_EXPORT_PATH}
YAML

kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pack_pod}" --timeout=300s
capture component-pack-pod kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod "${pack_pod}"
capture component-pack-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${pack_pod}" --tail=250

write_state remote-component-nfs-server "${NFS_SERVER}"
write_state remote-component-nfs-export-path "${NFS_EXPORT_PATH}"
write_state remote-component-nfs-run-dir "${nfs_run_dir}"
write_state remote-component-rebuilt-tar-path "${NFS_EXPORT_PATH%/}/${nfs_run_dir}/${rebuilt_tar_name}"
write_state remote-component-gcr-blob-path "${NFS_EXPORT_PATH%/}/${nfs_run_dir}/gcr-data/${blob_name}"

append_summary "# Remote Checkpoint Component Assembly" "" \
  "- source-node: ${source_node}" \
  "- verification-node: ${TARGET_NODE}" \
  "- receiver-storage: ${NFS_SERVER}:${NFS_EXPORT_PATH}/${nfs_run_dir}" \
  "- phase-1: checkpoint 구성 파일을 source tar 그대로 복사하지 않고 component directory로 전개 및 전송했다." \
  "- phase-2: verification node가 NFS receiver storage에서 SHA256SUMS를 모두 검증했다." \
  "- phase-3: receiver storage 안에서 ${rebuilt_tar_name} 재조립을 완료했다." \
  "- gcr-blob: gcr-data/${blob_name}" \
  "- restore-check-requested: ${RESTORE_CHECK}" \
  "" \
  "주의: 현재 스크립트는 CRI-O가 이미 만든 source checkpoint tar를 입력으로 읽어 component 단위 전송을 검증한다. source-side tar 생성을 완전히 제거하는 검증은 CRI-O checkpoint 경로 수정이 필요하다."

if [[ "${RESTORE_CHECK}" == "true" ]]; then
  append_summary "" "## Restore Check" "" "이 스크립트는 재조립 tar 생성까지만 자동화한다. Restore 검증은 scripts/11-run-cross-node-restore-from-nfs.sh 또는 별도 restore manifest에서 rebuilt tar와 gcr-data blob 경로를 사용해 수행한다."
fi

log "Remote checkpoint component assembly validated. Result: ${RESULT_DIR}"
