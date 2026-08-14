# HAMi 기반 Selective GPU Checkpoint/Restore 실험

이 저장소는 HAMi로 하나의 물리 GPU를 여러 CUDA Pod가 공유하는 환경에서, 특정 Pod 하나만 선택적으로 Checkpoint/Restore할 수 있는지 확인하기 위한 feasibility 실험 환경입니다.

연구 아이디어 이름은 **HAMi-Aware Selective Checkpoint/Restore for Shared GPUs**입니다.

## 실험 목표

- 같은 물리 GPU에서 HAMi Pod A와 Pod B를 동시에 실행합니다.
- Pod A만 Checkpoint 대상으로 지정합니다.
- Pod B는 Pod A의 Checkpoint/Restore 중에도 계속 CUDA 작업을 수행해야 합니다.
- Pod A를 같은 노드/같은 GPU에서 Restore합니다.
- 이후 Pod A를 삭제하고 새 Pod로 Restore합니다.
- 이번 기본 실험은 다른 Worker Node가 아니라 동일 Worker Node에서 Restore합니다.

이번 단계에서는 Dynamic Repacking, Bin-packing, MIG, MPS, NCCL, CUDA IPC, UVM은 다루지 않습니다.

## 저장소 구조

```text
.
├── config/      # 실험 환경 변수 예시와 로컬 env 생성 대상
├── scripts/     # 설치, 배포, 실험, 결과 수집, 복구 스크립트
├── manifests/   # Kubernetes namespace, RBAC, Pod, C/R CR manifest
├── workloads/   # CUDA 테스트 workload Dockerfile 및 소스
├── lib/         # Bash 공통 함수
├── docs/        # 실험/검증/장애 대응/복구 가이드
├── results/     # 실행 결과 저장 위치
├── backups/     # 클러스터 상태 백업 저장 위치
└── .state/      # 스크립트 상태 파일
```

## `config/experiment.env`는 어떻게 준비하나?

`config/experiment.env`는 GitHub에 올리지 않는 로컬 실행 설정 파일입니다.

직접 작성할 수도 있지만, 보통은 자동 생성 스크립트를 사용하면 됩니다.

```bash
./scripts/00-generate-experiment-env.sh
```

Makefile로 실행해도 됩니다.

```bash
make env
```

이미 파일이 있으면 덮어쓰지 않습니다. 다시 만들려면:

```bash
./scripts/00-generate-experiment-env.sh --force
```

생성 결과를 파일에 쓰지 않고 미리 보려면:

```bash
./scripts/00-generate-experiment-env.sh --dry-run
```

자동 생성 스크립트가 채우는 값:

- `kubectl`이 있으면 GPU Worker Node를 탐지해서 `SOURCE_NODE`를 채우고, 기본적으로 `TARGET_NODE`도 같은 노드로 설정합니다.
- 기존 체크포인트 저장소가 `../K8s-Native-Fast-GPU-Checkpoint-Restore-System`에 있으면 `GPUCheckpoint` 설치 경로를 사용합니다.
- 기존 restore 저장소가 `../K8s-Native-GPU-Restore-CRI-O`에 있으면 CRI-O restore 런타임 점검 가이드를 생성합니다.
- GCR 기본 hostPath인 `/var/lib/gcr-checkpoint`, `/var/lib/gcr-data`, `/var/lib/gpu-cr/lib`, `/var/lib/gpu-cr/run`을 채웁니다.
- HAMi 기본 리소스 이름을 채웁니다.
- Pod A/B를 각각 8GiB, 20% GPU core slice로 설정합니다.
- 기본 CUDA workload 실행 이미지를 `nvidia/cuda:12.4.1-devel-ubuntu22.04`로 설정합니다.

자동 탐지하지 못한 값은 나중에 실행 스크립트가 다시 탐지하거나, 필요한 단계에서 명확히 실패합니다.

## 워크로드를 직접 정해야 하나?

아니요. 기본 실험에서는 사용자가 워크로드를 따로 정하지 않아도 됩니다.

이 저장소가 이미 두 개의 CUDA workload를 제공합니다.

- Pod A: `workloads/selective-target/src/main.cu`
- Pod B: `workloads/co-runner/src/main.cu`

`scripts/05-deploy-test-workloads.sh`는 이 CUDA 소스를 Kubernetes ConfigMap으로 올리고, Pod 안에서 public CUDA devel image인 `nvidia/cuda:12.4.1-devel-ubuntu22.04`를 사용해 즉석에서 컴파일한 뒤 실행합니다.

즉 기본 흐름에서는 다음을 직접 준비하지 않아도 됩니다.

- 별도 workload 선택
- Dockerfile 수정
- 이미지 registry 선택
- `TARGET_IMAGE`, `CO_RUNNER_IMAGE` 수동 설정
- 커스텀 이미지 push

`scripts/04-build-test-images.sh`는 커스텀 이미지를 쓰고 싶을 때만 사용하는 선택 단계입니다. 기본 실험에서는 건너뛰어도 됩니다.

## 전체 실행 순서

### 1. 기존 C/R 저장소 준비

이 저장소와 같은 상위 디렉터리에 아래 두 저장소가 있어야 합니다.

```bash
git clone https://github.com/GProjectdev/K8s-Native-Fast-GPU-Checkpoint-Restore-System.git ../K8s-Native-Fast-GPU-Checkpoint-Restore-System
git clone https://github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O.git ../K8s-Native-GPU-Restore-CRI-O
```

이미 있으면 건너뜁니다.

첫 번째 저장소는 `GPUCheckpoint` CRD와 Node Agent를 제공합니다. 두 번째 저장소는 restore용 CRI-O patch, OCI hook, `gpu-cr-restore-agent.service`를 제공합니다.

중요: restore는 Kubernetes manifest만으로 끝나지 않습니다. 각 GPU Worker Node에서 CRI-O restore runtime 설치가 필요합니다.

### 2. 로컬 env 자동 생성

```bash
./scripts/00-generate-experiment-env.sh
cat config/experiment.env
```

### 3. 사전 점검

```bash
./scripts/00-preflight.sh
```

확인하는 것:

- 현재 kube-context
- Kubernetes API 접근 가능 여부
- GPU node 탐지
- Pod/Node 상태
- 결과 디렉터리 생성

### 4. 현재 클러스터 상태 백업

```bash
./scripts/01-backup-current-environment.sh
```

이 단계는 manifest와 상태를 저장할 뿐, 클러스터를 수정하지 않습니다.

### 5. HAMi 설치

```bash
./scripts/02-install-hami.sh --yes
```

이 스크립트는 GPU node에 `gpu=on` 라벨을 붙이고 HAMi Helm chart를 설치 또는 업그레이드합니다.

실제 적용 전 확인만 하려면:

```bash
./scripts/02-install-hami.sh --dry-run --yes
```

### 6. HAMi 설치 검증

```bash
./scripts/03-verify-hami.sh
```

### 7. GPUCheckpoint 시스템 설치

```bash
./scripts/04-install-gpu-cr-checkpoint-system.sh --yes
```

이 단계가 하는 일:

- `gpu-cr.io/v1alpha1` `GPUCheckpoint` CRD 설치
- `gpu-cr-node-agent` RBAC 설치
- GPU Worker Node에 `nvidia.com/gpu.present=true` 라벨 설정
- `gpu-cr-node-agent` DaemonSet 배포

### 8. Restore runtime 준비 확인

```bash
./scripts/04-check-gpu-cr-restore-runtime.sh
```

이 스크립트는 restore 저장소가 있는지 확인하고, 결과 디렉터리에 Worker Node에서 실행해야 할 명령을 남깁니다.

Worker Node마다 필요한 작업은 대략 아래와 같습니다.

```bash
cd ../K8s-Native-GPU-Restore-CRI-O
sudo bash hack/build-crio.sh
sudo bash scripts/install-node.sh
systemctl is-active crio
systemctl is-active gpu-cr-restore-agent.service
```

`scripts/install-node.sh`는 CRI-O 설정을 바꾸고 `crio`를 재시작합니다. 그래서 마스터에서 무조건 자동 실행하지 않고, 사용자가 GPU Worker Node에서 명시적으로 실행해야 합니다.

### 9. CUDA 테스트 workload 준비

```bash
./scripts/04-build-test-images.sh
```

기본 실험에서는 이 단계가 선택 사항입니다. Pod 배포 스크립트가 repo 안의 CUDA 소스를 ConfigMap으로 올리고, Pod 시작 시 public CUDA devel image 안에서 컴파일합니다.

커스텀 이미지를 쓰고 싶을 때만 `TARGET_IMAGE`, `CO_RUNNER_IMAGE`를 설정하고 이 스크립트를 사용하세요.

### 10. Pod A / Pod B 배포

```bash
./scripts/05-deploy-test-workloads.sh --yes
```

Pod A는 checkpoint 대상이고, Pod B는 계속 실행되어야 하는 co-runner입니다.

이 단계에서 실제로 하는 일:

- namespace/RBAC 적용
- Pod A CUDA source ConfigMap 생성
- Pod B CUDA source ConfigMap 생성
- Pod A/B manifest의 HAMi resource 값 치환
- Pod A/B 배포
- 두 Pod가 Ready가 될 때까지 대기

### 11. Baseline 수집

```bash
./scripts/06-run-baseline-test.sh
```

Pod A/B 로그와 `nvidia-smi` 결과를 `results/` 아래 timestamp 디렉터리에 저장합니다.

### 12. Pod A 선택적 Checkpoint 실험

```bash
./scripts/08-run-gcr-criu-selective-test.sh --yes
```

이 단계는 `gpu-cr.io/v1alpha1` `GPUCheckpoint`를 생성하고 `Completed` 상태를 기다립니다. 성공하면 `.state/` 아래에 restore에 필요한 값을 저장합니다.

- `.state/last-checkpoint-uri`
- `.state/last-checkpoint-data-uri`
- `.state/last-checkpoint-source-pod-uid`
- `.state/last-checkpoint-observed-node`

### 13. Pod 재생성 Restore 실험

```bash
./scripts/09-run-pod-recreation-test.sh --yes
```

이 단계는 `hami-pod-a`를 삭제하고 `hami-pod-a-restored` Pod를 생성합니다. Restore Pod에는 다음 annotation이 들어갑니다.

- `gpu-cr.io/restore=true`
- `gpu-cr.io/checkpoint-uri=hostpath:///var/lib/gcr-checkpoint/...tar`
- `gpu-cr.io/data-uri=hostpath:///var/lib/gcr-checkpoint/...blob`
- `gpu-cr.io/source-pod-uid=<원본 Pod UID>`

여기서 실패하면 대부분 Worker Node의 restore runtime, 즉 patched CRI-O, OCI hook, `gpu-cr-restore-agent.service`, CRIUgpu 설정 중 하나가 빠진 것입니다.

### 14. 결과 수집

```bash
./scripts/11-collect-results.sh
```

### 15. 실험 리소스 정리

```bash
./scripts/12-clean-test-resources.sh --yes
```

### 16. 원상복구

```bash
./scripts/99-rollback-to-original-environment.sh --yes
```

이 스크립트는 실험 namespace와 HAMi Helm release만 대상으로 합니다. Cilium, CoreDNS, Control Plane, VM은 건드리지 않습니다.

## 성공 기준

- Pod A와 Pod B가 같은 GPU Worker에서 HAMi GPU resource를 받아 실행됩니다.
- Pod A만 checkpoint 대상으로 처리됩니다.
- Pod B 로그 heartbeat가 checkpoint 전/중/후 계속 증가합니다.
- Pod B가 restart되지 않습니다.
- Pod A restore 후 CUDA heartbeat가 다시 이어집니다.
- Pod A가 동일 Worker Node에서 restore됩니다.

자세한 기준은 `docs/validation-criteria.md`를 확인하세요.

## 안전장치

모든 주요 스크립트는 다음 원칙을 따릅니다.

- `--dry-run` 지원
- 클러스터 변경 작업은 `--yes` 필요
- Node 이름, IP, GPU UUID 하드코딩 금지
- Cilium, CoreDNS, Control Plane 수정 금지
- `kubeadm reset` 금지
- VM 종료/삭제/재생성 금지
- 민감한 환경 변수 로그 출력 금지

## 문제 해결 문서

- 실험 절차: `docs/experiment-guide.md`
- 검증 기준: `docs/validation-criteria.md`
- 환경 리포트: `docs/environment-report.md`
- 장애 대응: `docs/troubleshooting.md`
- 원상복구: `docs/rollback-guide.md`

## 한 번에 전체 실험 실행하기

개별 명령을 하나씩 실행하지 않고 기본 실험 전체를 한 번에 돌리려면 아래 명령을 사용합니다.

```bash
./scripts/00-run-full-experiment.sh --yes
```

Makefile로도 실행할 수 있습니다.

```bash
make run
```

이 스크립트가 순서대로 실행하는 단계는 다음과 같습니다.

```text
01-generate-env        config/experiment.env 자동 생성
02-preflight           kube-context, node, GPU 탐지 사전 점검
03-backup              현재 클러스터 상태 백업
04-install-hami        HAMi 설치 또는 업그레이드
05-verify-hami         HAMi 구성 요소 상태 확인
06-install-gpu-cr-checkpoint  GPUCheckpoint CRD와 Node Agent 설치
07-check-restore-runtime      restore runtime 준비 상태 기록
08-deploy-workloads           Pod A/B 기본 CUDA workload 배포
09-baseline                   Checkpoint 전 baseline 수집
10-checkpoint-pod-a           Pod A만 checkpoint
11-restore-pod-a              Pod A restore
12-collect-results            최종 결과 수집
```

단계 목록만 보고 싶으면:

```bash
./scripts/00-run-full-experiment.sh --list
```

## 오류가 나면 어디서 멈췄는지 확인하기

전체 실행 스크립트는 실패한 단계에서 즉시 멈춥니다. 실패 지점은 아래 파일들에 남습니다.

```text
.state/full-experiment-current-stage
.state/full-experiment-last-failed-stage
.state/full-experiment-last-run-dir
results/<timestamp>-full-experiment/summary.md
results/<timestamp>-full-experiment/<NN-stage>.log
```

예를 들어 `10-checkpoint-pod-a` 단계에서 실패하면:

```text
.state/full-experiment-last-failed-stage
```

안에 다음처럼 기록됩니다.

```text
10-checkpoint-pod-a
```

해당 단계의 자세한 로그는 최근 run directory에서 확인합니다.

```bash
cat .state/full-experiment-last-run-dir
cat results/<timestamp>-full-experiment/10-10-checkpoint-pod-a.log
```

문제를 고친 뒤 같은 단계부터 다시 시작하려면:

```bash
./scripts/00-run-full-experiment.sh --yes --from 10-checkpoint-pod-a
```

## C/R CRD 없이 1차 확인하기

`GPUCheckpoint` CRD, `gpu-cr-node-agent`, CRI-O restore runtime이 없으면 진짜 GPU
Checkpoint/Restore는 검증할 수 없습니다.

하지만 아래 항목은 확인할 수 있습니다.

- HAMi에서 Pod A와 Pod B가 같은 Worker Node의 GPU slice를 받아 같이 실행되는지
- Pod A를 삭제해도 Pod B CUDA workload가 계속 실행되는지
- Pod A를 다시 만들었을 때 HAMi가 GPU slice를 다시 할당하는지
- Pod B가 restart되지 않고 heartbeat 로그가 계속 증가하는지

이 모드는 “Checkpoint/Restore 성공”을 증명하지는 않습니다. 대신 C/R 시스템을 붙이기
전에 HAMi 공유 GPU 격리성이 실험 가능한 상태인지 보는 1차 실험입니다.

실행:

```bash
./scripts/00-run-full-experiment.sh --yes --no-crd
```

또는:

```bash
make run-no-crd
```

no-CRD 모드 단계 목록:

```bash
./scripts/00-run-full-experiment.sh --no-crd --list
```

중간에 실패했다가 다시 시작하려면:

```bash
./scripts/00-run-full-experiment.sh --yes --no-crd --from 08-no-crd-isolation
```
