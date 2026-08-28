# HAMi 기반 GCR+CRIUgpu Checkpoint Overhead 측정 가이드

## 1. 측정 목적

이 측정의 목적은 HAMi 기반 GPU Sharing 환경에서 GCR+CRIUgpu 방식으로 checkpoint를 수행할 때 추가로 발생하는 자원 사용량을 확인하는 것이다.

대상 모델은 NFS에 저장된 다음 두 inference model이다.

- `gpt2`
- `facebook/opt-1.3b`

측정 대상 overhead는 다음과 같다.

- checkpoint 수행 시간
- checkpoint 전후 Pod CPU/Memory 사용량 변화
- checkpoint 전후 GPU utilization 변화
- checkpoint 전후 GPU memory 사용량 변화
- GPU-CR node agent, HAMi device plugin, HAMi scheduler의 CPU/Memory 변화
- checkpoint artifact 크기

## 2. 전제 조건

각 Worker Node는 다음 조건을 만족해야 한다.

- HAMi가 해당 Worker Node를 GPU node로 등록한 상태
- GCR+CRIUgpu checkpoint system이 설치된 상태
- inference Pod에서 `/opt/gpu-cr/libgcr-interceptor.so`를 mount할 수 있는 상태
- NFS 서버 `10.178.0.14:/mnt/nfs`에 접근 가능한 상태
- NFS에 모델 파일이 존재하는 상태

모델 경로는 다음과 같이 사용한다.

```text
NFS export: 10.178.0.14:/mnt/nfs
gpt2: /mnt/nfs/models/gpt2
opt-1.3b: /mnt/nfs/models/facebook/opt-1.3b
```

## 3. 측정 방식

측정은 모델별로 같은 절차를 반복한다.

1. Inference Pod 배포
2. 모델 load 및 steady inference loop 진입 확인
3. baseline window 동안 CPU/Memory/GPU 사용량 수집
4. `GPUCheckpoint` 생성
5. checkpoint window 동안 CPU/Memory/GPU 사용량 수집
6. checkpoint 완료 후 post window 동안 사용량 수집
7. checkpoint artifact와 Pod log 저장

측정 결과는 다음 구조로 저장된다.

```text
results/<timestamp>-checkpoint-overhead-<model>/
  summary.md
  checkpoint-durations.csv
  gpu-samples.csv
  pod-resource-samples.csv
  control-resource-samples.csv
  k8s-top-samples.txt
  checkpoint-artifact-sizes.txt
  gpucheckpoint-repeat-*.txt
  logs-after-repeat-*.txt
```

## 4. 설정값

기본 NFS 설정은 다음 값을 사용한다.

```bash
MODEL_NFS_SERVER=10.178.0.14
MODEL_NFS_EXPORT_PATH=/mnt/nfs
```

기본 inference image는 다음 값이다.

```bash
INFERENCE_IMAGE=pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime
```

해당 image에 `transformers`가 없으면 다음 옵션을 사용할 수 있다.

```bash
INFERENCE_PIP_INSTALL=true
```

단, Worker Node 또는 Pod에서 인터넷 접근이 되지 않는 환경이라면 pip install이 실패할 수 있다. 이 경우 `torch`, `transformers`, `accelerate`, `sentencepiece`가 포함된 사전 빌드 image를 만들어 `INFERENCE_IMAGE`로 지정하는 방식이 좋다.

## 5. gpt2 측정 절차

먼저 gpt2 inference Pod를 배포한다.

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore

INFERENCE_PIP_INSTALL=true \
bash ./scripts/13-deploy-inference-overhead-workload.sh \
  --model gpt2 \
  --yes
```

특정 Worker Node에 고정하려면 `--node`를 추가한다.

```bash
INFERENCE_PIP_INSTALL=true \
bash ./scripts/13-deploy-inference-overhead-workload.sh \
  --model gpt2 \
  --node jsj-worker-1 \
  --yes
```

Pod가 모델을 load하고 inference loop에 들어갔는지 확인한다.

```bash
kubectl -n hami-selective-cr logs hami-infer-gpt2 --tail=80
kubectl -n hami-selective-cr get pod hami-infer-gpt2 -o wide
```

그 다음 checkpoint overhead 측정을 실행한다.

```bash
bash ./scripts/14-run-checkpoint-overhead-benchmark.sh \
  --model gpt2 \
  --baseline-seconds 60 \
  --post-seconds 60 \
  --sample-interval-seconds 2 \
  --repeat 3 \
  --yes
```

## 6. opt-1.3b 측정 절차

`opt-1.3b`는 기본 경로로 `/mnt/nfs/models/facebook/opt-1.3b`를 사용한다.

```bash
INFERENCE_PIP_INSTALL=true \
bash ./scripts/13-deploy-inference-overhead-workload.sh \
  --model opt-1.3b \
  --yes
```

Pod 상태와 로그를 확인한다.

```bash
kubectl -n hami-selective-cr logs hami-infer-opt-1-3b --tail=80
kubectl -n hami-selective-cr get pod hami-infer-opt-1-3b -o wide
```

측정을 실행한다.

```bash
bash ./scripts/14-run-checkpoint-overhead-benchmark.sh \
  --model opt-1.3b \
  --baseline-seconds 60 \
  --post-seconds 60 \
  --sample-interval-seconds 2 \
  --repeat 3 \
  --yes
```

## 7. 결과 해석

`checkpoint-durations.csv`는 checkpoint 자체의 완료 시간을 확인하는 파일이다.

```csv
repeat,duration_ms,observed_node,checkpoint_count,checkpoint_path
```

`gpu-samples.csv`는 Pod 내부에서 `nvidia-smi`로 본 GPU 상태이다.

```csv
timestamp_utc,repeat,phase,gpu_timestamp,gpu_uuid,gpu_util_percent,mem_util_percent,gpu_mem_used_mb,gpu_mem_free_mb,power_w
```

`phase`는 다음 세 구간으로 나뉜다.

- `baseline`: checkpoint 전 steady inference 구간
- `checkpoint`: checkpoint 수행 중 구간
- `post`: checkpoint 완료 이후 구간

`k8s-top-samples.txt`는 다음 Kubernetes 자원 사용량을 함께 저장한다.

- inference Pod container CPU/Memory
- `gpu-cr-system` namespace의 GPU-CR component CPU/Memory
- `kube-system` namespace의 HAMi/NVIDIA plugin 관련 Pod CPU/Memory

동일한 내용 중 분석하기 쉬운 값은 다음 CSV에도 저장된다.

```text
pod-resource-samples.csv
control-resource-samples.csv
```

`checkpoint-artifact-sizes.txt`에는 checkpoint `.tar`와 external GPU memory `.blob` 파일 크기가 저장된다.

## 8. 비교 기준

모델별로 다음 값을 비교하면 된다.

| 항목 | 의미 |
|---|---|
| baseline 평균 GPU utilization | checkpoint 전 inference 부하 |
| checkpoint 구간 GPU utilization 변화 | checkpoint가 GPU 실행에 준 영향 |
| baseline 평균 Pod CPU/Memory | checkpoint 전 workload 자원 사용 |
| checkpoint 구간 Pod CPU/Memory 증가 | checkpoint로 인한 workload 측 overhead |
| gpu-cr-system CPU/Memory 증가 | checkpoint controller/node-agent 측 overhead |
| checkpoint duration | checkpoint 완료까지 걸린 시간 |
| checkpoint tar/blob 크기 | 저장/전송 overhead |

## 9. 주의 사항

`kubectl top`은 metrics-server가 있어야 동작한다. metrics-server가 없으면 `k8s-top-samples.txt`에 오류가 기록되지만 benchmark 자체는 계속 진행된다.

`nvidia-smi` 값은 물리 GPU 단위 값이다. 같은 GPU에 다른 workload가 같이 실행 중이면 GPU utilization과 memory 값에 함께 반영된다. 따라서 순수한 checkpoint overhead를 보려면 같은 실험 조건에서 baseline, checkpoint, post 구간을 비교해야 한다.

모델 파일은 NFS에 이미 존재하므로 측정 대상 overhead에 모델 다운로드 시간은 포함하지 않는다. 이 측정은 checkpoint 순간의 추가 비용을 보기 위한 것이며, cold start와 비교하려면 별도의 재배포 시간 측정이 필요하다.
