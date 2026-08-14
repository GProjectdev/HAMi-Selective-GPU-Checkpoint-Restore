# GPU Checkpoint/Restore 시스템 요구사항

## 결론

HAMi만으로는 GPU Checkpoint/Restore가 되지 않는다. HAMi는 GPU slice 스케줄링/공유 계층이고, 실제 C/R은 아래 시스템이 담당한다.

- Checkpoint: `GPUCheckpoint` CRD + `gpu-cr-node-agent` + kubelet checkpoint API + CRIUgpu + GCR interceptor
- Restore: patched CRI-O + checkpoint staging + OCI hook 또는 restore agent + GCR data remap

## Checkpoint에 필요한 것

- GPU Worker Node:
  - NVIDIA driver 570 이상 권장
  - CRI-O
  - kubelet `ContainerCheckpoint=true`
  - `criu`
  - NVIDIA `cuda_plugin.so`
  - `/var/lib/gcr-checkpoint`
  - `/var/lib/gcr-data`
  - `/var/lib/gpu-cr/lib`
  - `/var/lib/gpu-cr/run`
- Kubernetes:
  - `gpucheckpoints.gpu-cr.io` CRD
  - `gpu-cr-node-agent` DaemonSet
  - GPU Worker Node label `nvidia.com/gpu.present=true`
- Checkpoint 대상 Pod:
  - `LD_PRELOAD=/opt/gpu-cr/libgcr-interceptor.so`
  - `GCR_VMM_ALLOC=1`
  - `GCR_POD_UID` fieldRef
  - GCR hostPath mount

## Restore에 필요한 것

- GPU Worker Node:
  - restore 저장소의 CRI-O patch가 적용된 `crio`
  - `/etc/crio/crio.conf.d/99-gpu-cr-restore.conf`
  - OCI hook
  - `gpu-cr-restore-agent.service`
  - CRIU restore 설정 `/etc/criu/crun.conf`
- Restore Pod:
  - `gpu-cr.io/restore=true`
  - `gpu-cr.io/checkpoint-uri=hostpath:///...tar`
  - `gpu-cr.io/data-uri=hostpath:///...blob`
  - `gpu-cr.io/source-pod-uid=<원본 Pod UID>`

## 이 저장소가 자동화한 것

- HAMi 설치/검증
- `GPUCheckpoint` CRD/RBAC/Node Agent 적용
- Pod A/B CUDA workload 자동 생성
- Pod A에 GCR interceptor 환경변수와 hostPath mount 적용
- `GPUCheckpoint` 생성 및 완료 대기
- checkpoint tar/blob URI와 원본 Pod UID 저장
- restore annotation Pod 생성
- Pod B 지속성 로그 수집

## 이 저장소가 자동으로 하지 않는 것

각 Worker Node의 CRI-O 교체/재시작은 자동으로 하지 않는다. 이 작업은 노드 런타임을 바꾸는 작업이라 명시적으로 Worker Node에서 실행해야 한다.

```bash
cd ../K8s-Native-GPU-Restore-CRI-O
sudo bash hack/build-crio.sh
sudo bash scripts/install-node.sh
```

이후 실험 저장소에서 아래처럼 재개한다.

```bash
./scripts/00-run-full-experiment.sh --yes --from 10-checkpoint-pod-a
```
