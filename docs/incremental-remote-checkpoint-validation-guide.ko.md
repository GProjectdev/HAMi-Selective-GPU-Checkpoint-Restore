# Incremental Checkpoint + Remote Memory 전송 검증 가이드

## 1. 검증 목적

이번 검증의 목적은 GCR+CRIUgpu 기반 GPU Checkpoint에서 매번 전체 GPU data buffer를 저장하거나 전송하지 않고, 이전 checkpoint 이후 변경된 GPU data buffer 또는 변경된 chunk만 remote server memory로 전송할 수 있는지 확인하는 것이다.

최종적으로 확인하려는 질문은 다음과 같다.

```text
base checkpoint 이후 변경분만 remote server memory로 전송하고,
receiver가 base snapshot에 delta를 반영하여 최신 checkpoint artifact를 만들 수 있는가?
```

## 2. 현재까지 검증된 것과 새로 검증할 것

현재까지 검증된 내용은 다음과 같다.

```text
full GPU data buffer -> remote memory receiver 전송 가능
CRIU/CRI-O checkpoint 구성요소 -> remote storage로 분리 전송 가능
remote server에서 checkpoint archive 재조립 가능
```

이번에 새로 검증해야 하는 내용은 다음과 같다.

```text
base checkpoint 이후 변경분 식별
변경된 GPU data chunk만 remote memory로 전송
receiver가 base snapshot에 delta 적용
최신 .blob 또는 checkpoint artifact 재구성
```

즉, 현재 `tcp-mirror` 방식은 full GPU memory stream을 remote로 복제하는 POC이고, incremental checkpoint는 아직 별도 구현이 필요한 단계이다.

## 3. 논문 기준 Incremental Checkpoint의 의미

`GPU Checkpoint/Restore Made Fast and Lightweight` 논문에서 GCR은 GPU state를 크게 두 부분으로 나눈다.

```text
GPU control state:
  CUDA context, stream, driver-managed state 등

GPU data buffer:
  application이 cudaMalloc, cuMemAlloc 등으로 할당한 실제 GPU memory buffer
```

GCR의 핵심은 GPU data buffer만 selective interception으로 추적하고, GPU control state는 CRIUgpu 또는 driver-integrated checkpoint 경로에 맡기는 것이다.

논문에서 incremental checkpoint는 다음 의미를 가진다.

```text
첫 checkpoint:
  전체 GPU data buffer를 base snapshot으로 저장

이후 checkpoint:
  이전 checkpoint 이후 변경된 dirty buffer 또는 dirty range만 저장
```

논문은 dirty buffer 식별 비용을 줄이기 위해 CPU shadow execution과 dirty template을 사용한다고 설명한다. 따라서 단순히 `.tar`나 `.blob`을 압축하는 것은 논문이 말하는 incremental checkpoint가 아니다.

## 4. 구현 전략

처음부터 논문 수준의 dirty template을 구현하기보다는, 다음 3단계로 나눠 검증하는 것이 현실적이다.

| 단계 | 목표 | 의미 |
|---|---|---|
| 1차 | hash-diff 기반 delta POC | base와 현재 GPU data chunk hash를 비교하여 변경 chunk만 전송 |
| 2차 | dirty-map 기반 incremental | 실행 중 변경 후보 buffer/chunk를 기록하여 전체 비교 비용 감소 |
| 3차 | dirty template/shadow execution | 논문 방식에 가까운 fine-grained dirty 식별 |

가장 먼저 해야 할 것은 1차 `hash-diff` POC이다. 이 단계가 성공하면 remote server가 base snapshot과 delta만으로 최신 GPU data blob을 재구성할 수 있음을 보일 수 있다.

## 5. 1차 검증: Hash-diff 기반 Incremental POC

구조는 다음과 같다.

```text
Checkpoint 1
  모든 GPU data chunk 전송
  receiver가 base snapshot 저장
  sender/receiver가 chunk hash table 저장

Checkpoint 2
  GPU data를 chunk 단위로 hash 계산
  이전 hash와 다른 chunk만 delta로 전송
  receiver가 base snapshot의 해당 offset만 overwrite
  receiver가 reconstructed snapshot hash 계산
```

성공 기준은 다음과 같다.

```text
delta_bytes < full_bytes
delta_chunk_count < total_chunk_count
receiver_reconstructed_sha256 == sender_full_blob_sha256
restore에 사용할 수 있는 latest .blob 생성 가능
```

이 단계는 incremental remote checkpoint의 가능성을 검증하는 단계이다. 다만 hash 계산을 위해 전체 GPU data를 읽는다면 PCIe D2H 비용은 여전히 남을 수 있으므로, 논문 수준의 latency 감소를 바로 보장하지는 않는다.

## 6. Receiver에 필요한 기능

incremental remote checkpoint receiver는 단순히 chunk를 받아 로그를 남기는 프로그램이 아니라 base snapshot manager 역할을 해야 한다.

필요한 protocol은 다음과 같다.

```text
BEGIN_BASE:
  새 base checkpoint 시작
  전체 segment/chunk metadata 수신

BASE_CHUNK:
  full snapshot chunk 저장

BEGIN_DELTA:
  특정 base checkpoint id를 기준으로 delta generation 시작

DELTA_CHUNK:
  segment id, virtual address, segment offset, chunk offset, length, checksum 포함
  receiver memory 또는 tmpfs의 base snapshot 해당 위치에 overwrite

END:
  전체 수신 bytes, chunk 수, final hash 계산
  manifest/env summary 저장
```

receiver 저장 구조 예시는 다음과 같다.

```text
/dev/shm/gcr-incremental/
  run-001/
    metadata.env
    base/
      data.blob
      chunk-hashes.tsv
    generations/
      gen-0001.manifest.tsv
      gen-0002.delta.tsv
      gen-0002.reconstructed.sha256
```

remote memory 전송 가능성을 강조하려면 receiver의 base snapshot은 `/dev/shm` 또는 receiver process memory에 유지하는 것이 좋다.

## 7. Sender에 필요한 기능

GCR interceptor 또는 checkpoint agent 쪽에는 다음 기능이 필요하다.

```text
segment registry:
  GPU allocation의 VA, size, live/frozen 상태 추적

chunk metadata:
  segment를 고정 크기 chunk로 분할
  예: 2MiB 또는 16MiB

base hash table:
  이전 checkpoint의 chunk hash 저장

delta selector:
  현재 chunk hash와 이전 hash를 비교하거나 dirty map을 보고 전송 대상 결정

remote delta protocol:
  full checkpoint인지 incremental checkpoint인지 receiver에 전달
  base checkpoint id와 generation number 포함
```

환경 변수 설계 예시는 다음과 같다.

```bash
GCR_INCREMENTAL=hash-diff
GCR_INCREMENTAL_CHUNK_BYTES=2097152
GCR_INCREMENTAL_BASE_ID=auto
GCR_REMOTE_SINK=tcp-delta
GCR_REMOTE_HOST=10.178.0.14
GCR_REMOTE_PORT=19093
GCR_REMOTE_REQUIRED=true
```

## 8. Kubernetes 없이 먼저 검증할 수 있는 범위

incremental transfer protocol 자체는 Kubernetes 없이 먼저 검증할 수 있다.

Kubernetes 없이 검증할 수 있는 범위:

```text
GPU buffer allocation 추적
base checkpoint 생성
delta chunk 전송
receiver memory에 base + delta 적용
최종 blob checksum 검증
```

Kubernetes가 필요한 범위:

```text
HAMi vGPU Pod에서 동작하는지
GPUCheckpoint CRD와 연결되는지
CRI-O/CRIUgpu checkpoint tar와 함께 restore 가능한지
Pod 단위 selective checkpoint/restore가 유지되는지
```

따라서 개발 순서는 다음을 권장한다.

```text
1. 단일 Worker host에서 synthetic CUDA workload로 incremental delta protocol 검증
2. 같은 코드를 HAMi inference Pod에 적용하여 gpt2 checkpoint에서 delta 전송량 확인
3. receiver에서 reconstructed .blob 생성
4. 기존 component assembly 흐름과 합쳐 .tar + .blob artifact 생성
5. restore로 end-to-end 확인
```

## 9. Synthetic CUDA Workload 검증

gpt2 전에 synthetic workload를 먼저 쓰는 것이 좋다. 이유는 변경량을 사람이 정확히 통제할 수 있기 때문이다.

예시 시나리오:

```text
GPU buffer 총 크기: 512MiB
chunk size: 2MiB
총 chunk 수: 256

checkpoint 1:
  전체 buffer 초기화
  full checkpoint 전송

checkpoint 2:
  chunk 10, 11, 12만 수정
  incremental checkpoint 전송

예상:
  delta chunk count = 3
  delta bytes = 6MiB
  full bytes = 512MiB
```

이 결과가 맞으면 base/delta protocol 자체는 정상이라고 볼 수 있다.

## 10. gpt2 검증

synthetic 검증 후 기존 gpt2 inference Pod로 확인한다.

권장 흐름:

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore

bash ./scripts/13-deploy-inference-overhead-workload.sh \
  --model gpt2 \
  --yes

# base checkpoint
bash ./scripts/14-run-checkpoint-overhead-benchmark.sh \
  --model gpt2 \
  --baseline-seconds 60 \
  --post-seconds 30 \
  --sample-interval-seconds 2 \
  --repeat 1 \
  --yes
```

incremental checkpoint 검증은 같은 Pod를 유지한 상태에서 2회 이상 checkpoint해야 한다. 다만 이전 실험에서 반복 checkpoint 중 PyTorch CUDA `invalid argument` 문제가 있었으므로, 초기 검증은 synthetic workload를 먼저 사용하고 gpt2는 그 다음에 적용하는 것이 안전하다.

측정해야 할 값:

```text
full_gpu_bytes
delta_gpu_bytes
delta_ratio = delta_gpu_bytes / full_gpu_bytes
checkpoint_duration_ms
remote_transfer_duration_s
remote_throughput_mib_s
receiver_rss_mib
receiver_reconstructed_sha256
local_full_blob_sha256
```

성공 기준:

```text
delta_gpu_bytes < full_gpu_bytes
receiver_reconstructed_sha256 == local_full_blob_sha256
checkpoint 이후 gpt2 Pod Running 유지
restore artifact로 사용할 .blob 생성 가능
```

## 11. 구현 후 추가할 스크립트 후보

구현 후에는 다음 스크립트를 추가하면 된다.

```text
scripts/19-start-incremental-remote-receiver.sh
scripts/20-run-synthetic-incremental-checkpoint-test.sh
scripts/21-run-gpt2-incremental-remote-checkpoint-test.sh
scripts/22-summarize-incremental-checkpoint-results.sh
```

각 스크립트 역할:

| 스크립트 | 역할 |
|---|---|
| `19-start-incremental-remote-receiver.sh` | receiver server에서 base/delta receiver 실행 |
| `20-run-synthetic-incremental-checkpoint-test.sh` | synthetic CUDA buffer로 delta chunk 정확성 검증 |
| `21-run-gpt2-incremental-remote-checkpoint-test.sh` | gpt2 inference Pod에서 incremental 전송량/시간 측정 |
| `22-summarize-incremental-checkpoint-results.sh` | full vs incremental bytes/latency/throughput 요약 |

## 12. 최종적으로 주장할 수 있는 범위

구현 전 현재 시점에서 말할 수 있는 것은 다음이다.

```text
GCR 논문 구조상 incremental checkpoint는 dirty GPU data buffer만 저장/전송하는 방식으로 설계 가능하다.
현재 구현은 full GPU data buffer remote memory 전송과 receiver-side checkpoint component assembly를 이미 검증했다.
다음 구현 목표는 full remote stream을 base/delta stream으로 바꾸고,
receiver가 base snapshot에 delta를 적용하여 최신 checkpoint artifact를 조립하는 것이다.
```

구현 후 위 검증이 통과하면 다음과 같이 말할 수 있다.

```text
GCR+CRIUgpu 기반 HAMi GPU sharing workload에서
이전 checkpoint 이후 변경된 GPU data buffer만 remote server memory로 전송하고,
receiver가 이를 base snapshot에 반영하여 최신 checkpoint artifact를 재구성할 수 있음을 검증했다.
```

단, 논문 수준의 shadow execution/dirty template까지 구현하지 않은 상태라면 다음 표현은 피해야 한다.

```text
GCR 논문과 동일한 incremental checkpoint를 완전히 구현했다.
```

대신 다음 표현이 정확하다.

```text
GCR 논문의 incremental checkpoint 방향과 호환되는 base/delta remote checkpoint POC를 구현 및 검증했다.
```

## 13. 참고 자료

```text
https://www.usenix.org/conference/fast26/presentation/zeng
https://github.com/thustorage/GCR
https://criu.org/Page_server
```
