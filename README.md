# HAMi 기반 Selective GPU Checkpoint/Restore 실험

이 저장소는 HAMi로 하나의 물리 GPU를 여러 CUDA Pod가 공유하는 환경에서, 특정 Pod 하나만 선택적으로 Checkpoint/Restore할 수 있는지 확인하기 위한 feasibility 실험 환경입니다.

연구 아이디어 이름은 **HAMi-Aware Selective Checkpoint/Restore for Shared GPUs**입니다.

## 실험 목표

- 같은 물리 GPU에서 HAMi Pod A와 Pod B를 동시에 실행합니다.
- Pod A만 Checkpoint 대상으로 지정합니다.
- Pod B는 Pod A의 Checkpoint/Restore 중에도 계속 CUDA 작업을 수행해야 합니다.
- Pod A를 같은 노드/같은 GPU에서 Restore합니다.
- 이후 Pod A를 삭제하고 새 Pod로 Restore합니다.
- 가능하면 다른 Worker Node의 A100 GPU로 Cross-node Restore를 확장합니다.

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

- `kubectl`이 있으면 GPU Worker Node를 탐지해서 `SOURCE_NODE`, `TARGET_NODE`를 채웁니다.
- 기존 C/R 저장소가 `../K8s-Native-Fast-GPU-Checkpoint-Restore-System`에 있으면 GCR/CRIU 관련 경로를 최대한 탐색합니다.
- HAMi 기본 리소스 이름을 채웁니다.
- Pod A/B를 각각 8GiB, 20% GPU core slice로 설정합니다.
- 테스트 이미지 이름을 `ghcr.io/gprojectdev/...` 형식으로 채웁니다.

자동 탐지하지 못한 값은 나중에 실행 스크립트가 다시 탐지하거나, 필요한 단계에서 명확히 실패합니다.

## 전체 실행 순서

### 1. 기존 C/R 저장소 준비

이 저장소와 같은 상위 디렉터리에 기존 C/R 저장소가 있어야 GCR/CRIU 관련 값을 정확히 맞출 수 있습니다.

```bash
git clone https://github.com/GProjectdev/K8s-Native-Fast-GPU-Checkpoint-Restore-System.git ../K8s-Native-Fast-GPU-Checkpoint-Restore-System
```

이미 있으면 건너뜁니다.

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

### 7. CUDA 테스트 이미지 빌드

```bash
./scripts/04-build-test-images.sh
```

Kubernetes Worker가 이미지를 pull할 수 있어야 하므로, 실제 클러스터에서는 이미지 registry push가 필요할 수 있습니다.

### 8. Pod A / Pod B 배포

```bash
./scripts/05-deploy-test-workloads.sh --yes
```

Pod A는 checkpoint 대상이고, Pod B는 계속 실행되어야 하는 co-runner입니다.

### 9. Baseline 수집

```bash
./scripts/06-run-baseline-test.sh
```

Pod A/B 로그와 `nvidia-smi` 결과를 `results/` 아래 timestamp 디렉터리에 저장합니다.

### 10. Pod A 선택적 Checkpoint 실험

```bash
./scripts/08-run-gcr-criu-selective-test.sh --yes
```

중요: `manifests/checkpoint-resources.yaml`의 CRD group/kind/field는 기존 C/R 저장소의 실제 `WorkloadCheckpoint`, `WorkloadRestore` 정의에 맞춰 조정해야 합니다. 현재 파일은 실험 템플릿입니다.

### 11. Pod 재생성 Restore 실험

```bash
./scripts/09-run-pod-recreation-test.sh --yes
```

### 12. Cross-node Restore 실험

```bash
./scripts/10-run-cross-node-restore-test.sh --yes
```

먼저 같은 노드/같은 GPU Restore가 성공한 뒤 실행하는 것을 권장합니다.

### 13. 결과 수집

```bash
./scripts/11-collect-results.sh
```

### 14. 실험 리소스 정리

```bash
./scripts/12-clean-test-resources.sh --yes
```

### 15. 원상복구

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
- 가능하면 다른 A100 Worker Node에서도 restore가 성공합니다.

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

