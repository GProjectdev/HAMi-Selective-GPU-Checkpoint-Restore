# 실험 가이드

## 목표

HAMi가 하나의 물리 GPU를 Pod A와 Pod B에 나누어 준 상태에서, Pod A만 실제 GPU Checkpoint/Restore할 수 있는지 확인한다.

## 이번 실험에서 사용하는 실제 시스템

- Checkpoint: `K8s-Native-Fast-GPU-Checkpoint-Restore-System`
- Restore: `K8s-Native-GPU-Restore-CRI-O`

Checkpoint는 `gpu-cr.io/v1alpha1` `GPUCheckpoint`와 `gpu-cr-node-agent`가 담당한다. Restore는 patched CRI-O, OCI hook, `gpu-cr-restore-agent.service`, 그리고 Pod annotation `gpu-cr.io/restore`, `gpu-cr.io/checkpoint-uri`, `gpu-cr.io/source-pod-uid`가 담당한다.

## 포함 범위

- 동일 Worker Node restore
- 동일 물리 GPU에서 HAMi GPU slice 공유
- Pod A 단일 CUDA 프로세스 checkpoint
- Pod B CUDA heartbeat 지속성 확인
- Pod A 삭제 후 `hami-pod-a-restored` 생성

## 제외 범위

- 다른 Worker Node로 migration
- MIG, MPS, NCCL, CUDA IPC, UVM
- Deployment/StatefulSet 단위 fan-out
- Dynamic repacking/bin-packing

## 권장 실행 순서

```bash
git clone https://github.com/GProjectdev/K8s-Native-Fast-GPU-Checkpoint-Restore-System.git ../K8s-Native-Fast-GPU-Checkpoint-Restore-System
git clone https://github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O.git ../K8s-Native-GPU-Restore-CRI-O

./scripts/00-generate-experiment-env.sh --force
./scripts/00-preflight.sh
./scripts/01-backup-current-environment.sh
./scripts/02-install-hami.sh --yes
./scripts/03-verify-hami.sh
./scripts/04-install-gpu-cr-checkpoint-system.sh --yes
./scripts/04-check-gpu-cr-restore-runtime.sh
./scripts/05-deploy-test-workloads.sh --yes
./scripts/06-run-baseline-test.sh
./scripts/08-run-gcr-criu-selective-test.sh --yes
./scripts/09-run-pod-recreation-test.sh --yes
./scripts/11-collect-results.sh
```

한 번에 실행하려면:

```bash
./scripts/00-run-full-experiment.sh --yes
```

## Worker Node에서 별도로 필요한 restore 설치

Restore는 Kubernetes CRD만으로 동작하지 않는다. 각 GPU Worker Node에서 restore 저장소의 노드 설치가 필요하다.

```bash
cd ../K8s-Native-GPU-Restore-CRI-O
sudo bash hack/build-crio.sh
sudo bash scripts/install-node.sh
systemctl is-active crio
systemctl is-active gpu-cr-restore-agent.service
```

이 작업은 CRI-O를 재시작하므로 실험용 Worker Node에서 수행한다.

## 실패 지점별 의미

- `06-install-gpu-cr-checkpoint` 실패: 체크포인트 저장소 경로, CRD, RBAC, Node Agent manifest 확인
- `08-deploy-workloads` 실패: HAMi scheduler, GPU slice 용량, `/var/lib/gpu-cr/lib` 인터셉터 경로 확인
- `10-checkpoint-pod-a` 실패: `GPUCheckpoint` CRD, Node Agent, kubelet ContainerCheckpoint feature gate, CRIUgpu/cuda_plugin 확인
- `11-restore-pod-a` 실패: patched CRI-O, restore hook, `gpu-cr-restore-agent.service`, checkpoint tar/blob URI 확인

## 성공 판정

- Pod A/B가 같은 Worker Node에 배치된다.
- Pod B heartbeat가 Pod A checkpoint/restore 전후로 계속 증가한다.
- `GPUCheckpoint.status.phase=Completed`가 된다.
- `GPUCheckpoint.status.lastCheckpointPath`와 `.status.podUID`가 기록된다.
- `hami-pod-a-restored`가 Ready가 되고 CUDA 로그를 출력한다.
