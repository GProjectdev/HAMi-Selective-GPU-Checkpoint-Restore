# HAMi Shared GPU Checkpoint Interference 검증 가이드

이 문서는 HAMi shared GPU 환경에서 GCR+CRIUgpu 기반 checkpoint가 같은 물리 GPU를 공유하는 workload에 간섭을 주는지 검증하기 위한 실행 가이드이다.

## 1. 왜 GCR+CRIUgpu System으로 해야 하는가

이번 검증의 질문은 단순한 GPU 부하 측정이 아니다.

검증하려는 것은 다음이다.

- GCR selective interception이 GPU memory buffer를 checkpoint 대상으로 잡는가
- CRIUgpu/GPUCheckpoint 경로가 실제 checkpoint를 수행하는가
- checkpoint 중 같은 물리 GPU를 공유하는 다른 HAMi workload의 latency/throughput이 변하는가
- 여러 Pod를 동시에 checkpoint하면 checkpoint 시간이 증가하는가

따라서 일반 `nvidia-smi` 부하 테스트나 PyTorch workload만으로는 충분하지 않다. 반드시 기존에 구현한 `GPUCheckpoint` CRD, `gpu-cr-node-agent`, GCR interceptor, CRIUgpu 경로를 사용해야 한다.

## 2. 현재 환경에서 초기에 확인할 것

Master node:

```bash
kubectl get nodes -o wide
kubectl get pods -A | grep -Ei 'hami|gpu-cr|checkpoint'
kubectl get crd | grep -i gpucheckpoint
kubectl top nodes
```

Worker node:

```bash
nvidia-smi -L
mount | grep '10.178.0.14:/mnt/nfs'
df -h /mnt/nfs
```

성공 조건:

- HAMi scheduler/device-plugin이 Running
- gpu-cr-node-agent가 GPU worker마다 Running
- `GPUCheckpoint` CRD가 존재
- metrics-server가 동작해서 `kubectl top nodes`가 성공
- `/mnt/nfs/models/gpt2` 또는 `/mnt/nfs/models/facebook/opt-1.3b` 접근 가능

## 3. 초기에 바꿔야 하는 설정

`config/experiment.env`에 아래 값이 없으면 추가하거나 현재 환경에 맞게 수정한다.

```bash
NFS_SERVER=10.178.0.14
NFS_EXPORT_PATH=/mnt/nfs

GPU_CR_LIB_HOST_PATH=/opt/gpu-cr
GCR_CONTROL_DIR=/var/lib/gpu-cr/run
GCR_DATA_DIR=/var/lib/gcr-data
CHECKPOINT_STORAGE_TYPE=hostPath
CHECKPOINT_STORAGE_PATH=/var/lib/gcr-checkpoint

INFERENCE_PIP_INSTALL=true
INFERENCE_PIP_PACKAGES="transformers==4.44.2 accelerate==0.34.2 sentencepiece protobuf"
```

주의할 점:

- 이 실험은 cross-node restore가 아니다.
- 모든 workload Pod는 같은 worker node에 배치되어야 한다.
- `nodeName`으로 scheduler를 우회하지 않는다.
- Pod manifest는 `schedulerName: hami-scheduler`와 `nodeSelector`를 사용한다.

## 4. 실험 단계 구분

이 검증은 두 단계로 나누어 진행한다.

| 단계 | 목적 | 권장 workload | 반복 |
|---|---|---|---:|
| Phase 1-A | 스크립트와 GCR+CRIUgpu 흐름 확인 | `gpt2` model workload | 3회 |
| Phase 1-B | 실제 간섭 characterization | synthetic CUDA payload 2GB/4GB/8GB 또는 큰 모델 | 최소 5회, 가능하면 10회 |
| Phase 2 | periodic checkpoint 정책 비교 | synchronized vs staggered | 최소 5회 |

GPT-2는 기능 흐름 확인에는 좋지만 실제 GPU payload가 수백 MB 수준일 수 있다. 따라서 연구 결과로 쓰려면 `--workload-kind synthetic`으로 payload 크기를 통제하거나, 더 큰 모델로 확장하는 것이 좋다.

## 5. Shared GPU workload 배포

처음에는 `gpt2`로 시작한다.

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore

bash ./scripts/19-deploy-shared-gpu-interference-workloads.sh \
  --model gpt2 \
  --node jsj-worker-2 \
  --pod-count 3 \
  --gpu-memory-mb 8192 \
  --gpu-core-percent 30 \
  --yes
```

payload contention을 더 명확히 보려면 synthetic workload를 사용한다.

```bash
bash ./scripts/19-deploy-shared-gpu-interference-workloads.sh \
  --model gpt2 \
  --node jsj-worker-2 \
  --pod-count 3 \
  --workload-kind synthetic \
  --synthetic-alloc-mb 4096 \
  --gpu-memory-mb 8192 \
  --gpu-core-percent 30 \
  --yes
```

배포 확인:

```bash
kubectl -n hami-selective-cr get pods -l experiment.gpu-cr/role=shared-gpu-interference -o wide
kubectl -n hami-selective-cr get pods -l experiment.gpu-cr/role=shared-gpu-interference -o yaml | \
  grep -E 'hami.io/vgpu-devices-allocated|schedulerName|nodeName'
```

로그 확인:

```bash
kubectl -n hami-selective-cr logs hami-interf-gpt2-a --tail=30
kubectl -n hami-selective-cr logs hami-interf-gpt2-b --tail=30
kubectl -n hami-selective-cr logs hami-interf-gpt2-c --tail=30
```

정상 로그 예시는 다음과 같다.

```text
[interference] ready pod=hami-interf-gpt2-a worker=a
[interference] ts=... pod=hami-interf-gpt2-a ... iteration=10 latency_s=... ips=...
```

## 6. Checkpoint interference benchmark 실행

디버깅용 1차 실행:

```bash
bash ./scripts/20-run-shared-gpu-checkpoint-interference-benchmark.sh \
  --model gpt2 \
  --baseline-seconds 60 \
  --post-seconds 60 \
  --sample-interval-seconds 1 \
  --repeat 3 \
  --yes
```

본 실험 실행:

```bash
bash ./scripts/20-run-shared-gpu-checkpoint-interference-benchmark.sh \
  --model gpt2 \
  --baseline-seconds 60 \
  --post-seconds 60 \
  --sample-interval-seconds 1 \
  --repeat 5 \
  --recreate-between-repeats \
  --yes
```

스크립트가 수행하는 일:

- Pod A/B/C steady-state 확인
- no-checkpoint baseline 수집
- solo checkpoint 측정
- sequential A->B->C checkpoint 측정
- concurrent checkpoint 2개 측정
- concurrent checkpoint 3개 측정
- staggered checkpoint 측정
- node CPU/memory 샘플 수집
- Pod CPU/memory 샘플 수집
- GPU utilization/memory/power 샘플 수집
- checkpoint duration, payload bytes CSV 생성
- scenario별 Makespan CSV 생성
- CCI factor 요약 생성
- CEI 자동 계산

## 7. 결과 위치

결과는 다음 형태로 생성된다.

```text
results/<timestamp>-shared-gpu-checkpoint-interference-gpt2/
```

주요 파일:

```text
summary.md
shared-gpu-interference-summary.csv
checkpoint-durations.csv
checkpoint-makespan.csv
checkpoint-makespan-summary.csv
cei-summary.csv
node-resource-samples.csv
pod-resource-samples.csv
gpu-samples.csv
logs-*.txt
gpucheckpoint-*.txt
```

요약 확인:

```bash
RESULT=$(cat .state/last-shared-gpu-interference-result-dir)
cat "$RESULT/summary.md"
cat "$RESULT/checkpoint-durations.csv"
cat "$RESULT/checkpoint-makespan.csv"
cat "$RESULT/shared-gpu-interference-summary.csv"
cat "$RESULT/cei-summary.csv"
```

## 8. 결과 해석

### CCI: Checkpoint-to-Checkpoint Interference

`shared-gpu-interference-summary.csv`의 `cci_factor_vs_solo`를 본다.

```text
CCI factor = concurrent checkpoint 평균 시간 / solo checkpoint 평균 시간
```

주의: `1.2`, `1.5` 같은 값은 보편적인 기준이 아니라 내부 판단용 heuristic이다. 최종 판단은 반복 실험의 평균, 표준편차, p95, Makespan, CEI를 함께 보고 한다.

### Makespan

`checkpoint-makespan-summary.csv`를 본다.

```text
T_makespan = max(checkpoint end_i) - min(checkpoint start_i)
```

Makespan은 evacuation 관점에서 더 중요한 값이다. 예를 들어 concurrency가 올라가면 개별 checkpoint는 느려져도 전체 Makespan은 줄어들 수 있다. 이 trade-off가 확인되어야 checkpoint orchestration 연구 근거가 생긴다.

### CEI: Checkpoint-to-Execution Interference

Pod 로그의 `ips` 또는 `latency_s`를 checkpoint 전후 window로 나누어 비교한다.

```text
CEI = 1 - (checkpoint 중 sibling Pod ips / baseline sibling Pod ips)
```

해석:

- `0.0` 근처: checkpoint가 sibling workload 처리량에 거의 영향 없음
- `0.1` 이상: checkpoint 중 co-tenant 성능 저하 가능성 있음
- `0.3` 이상: checkpoint scheduling 정책 필요성이 큼

`cei-summary.csv`에 sibling Pod별 baseline/during/post ips와 CEI가 자동 저장된다.

## 9. 권장 실험 Case

최소 실험 세트는 다음 6개이다.

| Case | 목적 | 스크립트 반영 |
|---|---|---|
| No Checkpoint | Shared-GPU 정상 실행 baseline | `no_checkpoint` |
| Solo A | A checkpoint가 sibling B/C에 주는 영향 | `solo` |
| Sequential A->B->C | Concurrency=1 기준 Makespan | `sequential` |
| Concurrent A+B | Concurrency=2 경합과 C slowdown | `concurrent2` |
| Concurrent A+B+C | Concurrency=3 경합 | `concurrent3` |
| Staggered | checkpoint burst 분산 효과 | `staggered` |

## 10. opt-1.3b로 확장

gpt2에서 실험 흐름이 안정화되면 opt-1.3b로 확장한다.

```bash
bash ./scripts/19-deploy-shared-gpu-interference-workloads.sh \
  --model opt-1.3b \
  --node jsj-worker-2 \
  --pod-count 2 \
  --gpu-memory-mb 12288 \
  --gpu-core-percent 40 \
  --yes

bash ./scripts/20-run-shared-gpu-checkpoint-interference-benchmark.sh \
  --model opt-1.3b \
  --baseline-seconds 120 \
  --post-seconds 60 \
  --sample-interval-seconds 1 \
  --repeat 5 \
  --recreate-between-repeats \
  --yes
```

opt-1.3b는 GPU memory 사용량이 크기 때문에 처음에는 Pod 2개로 시작한다. 정상적으로 shared placement가 되면 Pod 3개로 늘린다.

## 11. 실패 시 빠른 판단

### UUID Not Found

HAMi annotation이 stale GPU UUID를 들고 있을 가능성이 있다.

```bash
kubectl -n hami-selective-cr get pod <pod> -o yaml | grep -E 'hami.io/vgpu-devices-allocated|nvidia.com/use-gpuuuid'
kubectl get node <node> -o jsonpath='{.metadata.annotations.hami\.io/node-nvidia-register}{"\n"}'
```

Pod를 삭제하고 HAMi device-plugin/scheduler를 재시작한 뒤 다시 배포한다.

### Pod가 서로 다른 node에 배치됨

`--node` 값을 명시한다. 이 스크립트는 `nodeSelector`와 `hami-scheduler`를 같이 사용한다.

### checkpoint가 Completed가 되지 않음

```bash
kubectl -n hami-selective-cr get gpucheckpoint -o wide
kubectl -n hami-selective-cr describe gpucheckpoint <name>
kubectl -n hami-selective-cr logs <pod> --tail=120
```

GCR 로그에 다음이 있어야 한다.

```text
[gcr] checkpoint signal received
[gcr][engine] freeze:
[gcr] checkpoint ACK sent
```

### 반복 checkpoint 후 CUDA error

반복 checkpoint는 워크로드 상태를 오염시킬 수 있다. 실험 표에는 실패 run을 별도로 표시하고, 다음 run 전에 Pod를 재배포한다.

```bash
bash ./scripts/19-deploy-shared-gpu-interference-workloads.sh --model gpt2 --node jsj-worker-2 --pod-count 3 --yes
```

## 12. 교수님께 보여줄 수 있는 결론 형태

아래 항목을 채우면 된다.

```text
1. 동일 A100 물리 GPU 위에 HAMi shared GPU Pod 3개를 배치했다.
2. 각 Pod는 GCR interceptor가 적용된 CUDA inference workload이다.
3. GPUCheckpoint CRD로 Pod 1개, 2개, 3개 checkpoint를 수행했다.
4. solo 대비 concurrent checkpoint 시간이 증가하면 CCI가 존재한다.
5. checkpoint 중 sibling Pod의 ips가 감소하면 CEI가 존재한다.
6. 따라서 shared GPU 환경에서는 checkpoint를 단순 병렬 실행하지 않고 scheduling/orchestration 해야 한다.
```
