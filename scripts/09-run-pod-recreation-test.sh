#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/result.sh"

parse_common_args "$@"
load_env
init_result_dir pod-recreation
require_kubectl
require_cmd envsubst
confirm_destructive "Deleting Pod A and creating restore Pod from GPUCheckpoint artifacts"

state_dir="${REPO_ROOT}/${STATE_ROOT#./}"
RESTORE_CHECKPOINT_URI="${RESTORE_CHECKPOINT_URI:-$(cat "${state_dir}/last-checkpoint-uri" 2>/dev/null || true)}"
RESTORE_DATA_URI="${RESTORE_DATA_URI:-$(cat "${state_dir}/last-checkpoint-data-uri" 2>/dev/null || true)}"
RESTORE_SOURCE_POD_UID="${RESTORE_SOURCE_POD_UID:-$(cat "${state_dir}/last-checkpoint-source-pod-uid" 2>/dev/null || true)}"
RESTORE_GPU_UUID="${RESTORE_GPU_UUID:-$(cat "${state_dir}/last-hami-gpu-uuid" 2>/dev/null || true)}"
RESTORE_BLOB_MODE="${RESTORE_BLOB_MODE:-copy}"
observed_node="$(cat "${state_dir}/last-checkpoint-observed-node" 2>/dev/null || true)"
TARGET_NODE="${TARGET_NODE:-${observed_node}}"

[[ -n "${RESTORE_CHECKPOINT_URI}" ]] || die "Missing restore checkpoint URI. Run scripts/08-run-gcr-criu-selective-test.sh --yes first."
[[ -n "${RESTORE_SOURCE_POD_UID}" ]] || die "Missing source Pod UID. Run scripts/08-run-gcr-criu-selective-test.sh --yes first."
[[ -n "${TARGET_NODE}" ]] || die "TARGET_NODE is empty and checkpoint observed node was not recorded."
[[ -n "${RESTORE_GPU_UUID}" ]] || die "Missing HAMi GPU UUID. Re-run scripts/08-run-gcr-criu-selective-test.sh --yes with a HAMi-bound Pod A, or set RESTORE_GPU_UUID manually."

# HAMi injects these paths through the device plugin when the original Pod is
# created. CRIU restore validates the checkpointed bind mounts before the device
# plugin can transparently recreate them, so the restore Pod must provide the
# same destination paths explicitly.
RESTORE_HAMI_VGPU_LOCK_SOURCE="${RESTORE_HAMI_VGPU_LOCK_SOURCE:-/tmp/vgpulock}"
RESTORE_HAMI_LD_PRELOAD_SOURCE="${RESTORE_HAMI_LD_PRELOAD_SOURCE:-/usr/local/vgpu/ld.so.preload}"
RESTORE_HAMI_ORIGINAL_VGPU_DIR_SOURCE="${RESTORE_HAMI_ORIGINAL_VGPU_DIR_SOURCE:-/usr/local/vgpu/containers/${RESTORE_SOURCE_POD_UID}_selective-target}"
RESTORE_HAMI_VGPU_DIR_SOURCE="${RESTORE_HAMI_VGPU_DIR_SOURCE:-/usr/local/vgpu/restore-cache/${RESTORE_SOURCE_POD_UID}_selective-target}"
RESTORE_HAMI_LIBVGPU_SOURCE="${RESTORE_HAMI_LIBVGPU_SOURCE:-/usr/local/vgpu/libvgpu.so.v2.9.0}"

export RESTORE_CHECKPOINT_URI RESTORE_DATA_URI RESTORE_SOURCE_POD_UID RESTORE_GPU_UUID RESTORE_BLOB_MODE TARGET_NODE
export RESTORE_HAMI_VGPU_LOCK_SOURCE RESTORE_HAMI_LD_PRELOAD_SOURCE RESTORE_HAMI_VGPU_DIR_SOURCE RESTORE_HAMI_LIBVGPU_SOURCE

cache_hami_vgpu_dir() {
  local helper="hami-restore-hami-cache"

  log "Caching HAMi vGPU directory on ${TARGET_NODE}: ${RESTORE_HAMI_ORIGINAL_VGPU_DIR_SOURCE} -> ${RESTORE_HAMI_VGPU_DIR_SOURCE}"
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${helper}" --ignore-not-found=true --wait=true >/dev/null
  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${helper}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app.kubernetes.io/name: hami-selective-cr
    experiment.gpu-cr/role: restore-helper
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${TARGET_NODE}
  containers:
    - name: cache
      image: ${WORKLOAD_BASE_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-lc"]
      args:
        - |
          set -Eeuo pipefail
          src="/host${RESTORE_HAMI_ORIGINAL_VGPU_DIR_SOURCE}"
          dst="/host${RESTORE_HAMI_VGPU_DIR_SOURCE}"
          if [ -d "\${dst}" ]; then
            echo "HAMi restore cache already exists: \${dst}"
            exit 0
          fi
          if [ ! -d "\${src}" ]; then
            echo "Missing original HAMi vGPU directory: \${src}" >&2
            echo "Re-run scripts/05-deploy-test-workloads.sh --yes and scripts/08-run-gcr-criu-selective-test.sh --yes before restore." >&2
            exit 42
          fi
          mkdir -p "\$(dirname "\${dst}")"
          rm -rf "\${dst}.tmp"
          cp -a "\${src}" "\${dst}.tmp"
          mv "\${dst}.tmp" "\${dst}"
          echo "Cached HAMi vGPU directory: \${dst}"
      securityContext:
        privileged: true
      volumeMounts:
        - name: host-root
          mountPath: /host
  volumes:
    - name: host-root
      hostPath:
        path: /
        type: Directory
YAML
  if ! kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=condition=Ready "pod/${helper}" --timeout=120s >/dev/null 2>&1; then
    :
  fi
  if ! kubectl -n "${EXPERIMENT_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${helper}" --timeout=120s; then
    kubectl -n "${EXPERIMENT_NAMESPACE}" describe pod "${helper}" || true
    kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${helper}" --tail=120 || true
    die "Failed to cache HAMi vGPU directory before restore."
  fi
  kubectl -n "${EXPERIMENT_NAMESPACE}" logs "${helper}" --tail=80
  kubectl -n "${EXPERIMENT_NAMESPACE}" delete pod "${helper}" --ignore-not-found=true --wait=false >/dev/null
}

if [[ "${DRY_RUN}" != "true" ]]; then
  cache_hami_vgpu_dir
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
capture restored-logs kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-a-restored --tail=200
capture pod-b-after-restore kubectl -n "${EXPERIMENT_NAMESPACE}" logs hami-pod-b --tail=200
append_summary "# Pod A Restore" "" "- restore pod: hami-pod-a-restored" "- checkpoint-uri: ${RESTORE_CHECKPOINT_URI}" "- data-uri: ${RESTORE_DATA_URI:-default .tar -> .blob}" "- source-pod-uid: ${RESTORE_SOURCE_POD_UID}" "- target-node: ${TARGET_NODE}" "- hami-gpu-uuid: ${RESTORE_GPU_UUID}"
