# GCR+CRIUgpu Checkpoint Data 원격 Host Memory 직접 전송 가능성 검증 가이드

## 1. 검증 목표

이번 검증의 목표는 Kubernetes 스케줄링이나 Pod Restore 성공 여부가 아니라, GCR+CRIUgpu 방식의 Checkpoint 과정에서 생기는 메모리 데이터를 CRIU page-server처럼 다른 Host Server의 memory로 직접 전송할 수 있는지 확인하는 것이다.

여기서 "직접 전송"은 이미 생성된 `.tar`와 `.blob` 파일을 복사하는 것이 아니다. Checkpoint 수행 중 GPU memory가 host memory staging buffer로 내려오는 시점에, 그 데이터를 디스크 파일로 확정하기 전에 네트워크를 통해 다른 Host의 memory로 보내는 것을 의미한다.

현재 Checkpoint 데이터는 두 종류로 나뉜다.

| 구분 | 현재 실험에서의 형태 | 의미 |
|---|---|---|
| CPU/process checkpoint | `checkpoint-...tar` 내부의 CRIU image | 프로세스 주소 공간, fd, mount, cgroup, namespace 등 CRIU가 저장한 상태 |
| GPU memory checkpoint | `checkpoint-...blob` | GCR selective interception이 CUDA allocation을 추적한 뒤 외부 blob으로 저장한 GPU 데이터 |

따라서 이 검증은 다음 질문에 답하는 형태로 진행한다.

1. CRIU page-server가 처리할 수 있는 데이터 범위는 어디까지인가?
2. GCR가 checkpoint 중 host staging memory에 올린 GPU 데이터를 file sink 없이 remote memory sink로 보낼 수 있는가?
3. 전송된 데이터가 원본 GPU snapshot과 동일한가?
4. 전송 시간, 처리량, 원격 Host memory 사용량은 어느 정도인가?
5. 이 방식이 바로 Restore 입력으로 사용 가능한가, 아니면 추가 구현이 필요한가?

## 2. CRIU Page-server와 GCR Blob의 차이

CRIU의 `page-server`는 CRIU가 dump하는 CPU memory page를 네트워크로 보내기 위한 기능이다. CRIU 문서와 man page 기준으로 `page-server`는 `criu page-server` 명령으로 실행되며, dump/restore 과정에서 CRIU page image를 원격으로 보내거나 lazy-pages 방식으로 필요한 page를 나중에 가져오는 데 사용된다.

중요한 점은 CRIU page-server가 "임의의 파일 전송 서버"가 아니라는 것이다. 현재 GCR+CRIUgpu 구조에서 생성되는 `checkpoint-...blob`은 CRIU page image가 아니라 GCR가 별도로 만든 external GPU memory blob이다. 그러므로 현재 구현 그대로는 GPU blob이 CRIU page-server 프로토콜에 자동으로 실려 전송되지 않는다.

정리하면 다음과 같다.

| 항목 | CRIU page-server | 현재 GCR external blob |
|---|---|---|
| 대상 | CRIU가 관리하는 CPU memory pages | GCR가 추적한 CUDA allocation 데이터 |
| 전송 방식 | CRIU 내부 page-server/lazy-pages 프로토콜 | 별도 data sink 필요 |
| 현재 실험에서 자동 연동 여부 | CPU checkpoint 영역에만 해당 | 자동 연동되지 않음 |
| 검증 가능한 방식 | CRIU 단독 page-server 실험 | GCR `g_stage` 데이터를 remote sink로 전송하는 POC |

따라서 이번 검증에서 확인해야 하는 것은 두 단계다.

```text
1단계: CRIU page-server가 CPU memory page를 원격 Host로 직접 전송할 수 있음을 확인한다.
2단계: GCR selective interception 경로의 GPU D2H staging 데이터를 file sink 대신 remote-memory sink로 보낼 수 있음을 확인한다.
```

## 3. 어디까지 전송 가능한가

현재 코드 기준으로 즉시 가능한 것과 추가 구현이 필요한 것은 다음과 같다.

| 범위 | 가능 여부 | 설명 |
|---|---:|---|
| CPU memory page-server 전송 | 가능 | CRIU가 관리하는 anonymous/private CPU page 대상 |
| Checkpoint `.tar` 원격 전송 | 가능 | 일반 파일/stream이므로 가능하지만 직접 checkpoint memory 전송 증거는 아님 |
| GPU `.blob` 원격 전송 | 가능 | 일반 파일/stream이므로 가능하지만 직접 checkpoint memory 전송 증거는 아님 |
| CRIU page-server로 GPU blob 직접 전송 | 현재는 불가 | blob은 CRIU page image가 아니므로 page-server 대상이 아님 |
| GCR freeze 중 GPU data 직접 전송 | 추가 구현 필요 | `g_blob` file sink 대신 remote sink를 추가해야 함 |
| 원격 메모리에서 바로 Restore | 추가 구현 필요 | Restore runtime이 remote memory source 또는 target tmpfs source를 읽어야 함 |

즉 "가능성 검증"은 artifact 복사 실험만으로는 부족하다. 실제 가능성을 보려면 GCR interceptor의 data sink를 바꾸는 최소 구현이 필요하다.

## 4. 현재 GCR 코드에서 직접 전송을 붙일 위치

현재 GCR selective interception의 핵심 경로는 Checkpoint 시스템 repo의 다음 파일에 있다.

```text
K8s-Native-Fast-GPU-Checkpoint-Restore-System/interceptor/preload.c
```

코드 흐름은 다음과 같다.

```text
cudaMalloc hook
  -> GCR이 CUDA VMM으로 allocation을 소유
  -> g_owned[]에 VA, size, handle, prop 기록

checkpoint signal
  -> checkpoint_freeze()
  -> GPU memory D2H copy
  -> g_stage 또는 g_stageA/g_stageB host staging buffer
  -> g_blob mmap file에 memcpy
  -> cuMemUnmap + cuMemRelease로 해당 allocation의 physical GPU memory release
  -> g_blob munmap/close
  -> CRIUgpu가 나머지 CPU/control state checkpoint
```

현재 직접 전송을 붙일 수 있는 지점은 두 곳이다.

| 위치 | 의미 | 장단점 |
|---|---|---|
| `g_stage`에서 바로 send | GPU에서 내려온 chunk를 즉시 remote로 전송 | 가장 page-server 유사, 디스크 경유 최소화 |
| `g_blob` mmap 이후 send | file-backed page cache에 쓴 뒤 전송 | 구현은 쉬우나 "직접 메모리 전송" 주장은 약함 |

검증 목표가 page-server와 유사한 직접 전송이면 첫 번째 방식, 즉 `g_stage` chunk를 remote socket으로 보내는 방식이 맞다.

## 5. 권장 실험 구조

이 실험은 Kubernetes 없이 진행하는 것을 권장한다. 이유는 Kubernetes/HAMi/CRI-O 변수를 제거하고, GCR data path 자체가 remote memory sink로 동작하는지만 먼저 확인하는 것이 더 정확하기 때문이다.

### 5.1 Host 구성

| 역할 | 예시 Host | 필요 조건 |
|---|---|---|
| Source Host | GPU가 있는 서버 | GCR interceptor, CUDA workload, CRIUgpu 또는 최소 freeze trigger |
| Receiver Host | 다른 서버 | 충분한 RAM, receiver process, checksum/byte counter |

### 5.2 실험 단계

| 단계 | 목적 | Kubernetes 필요 여부 |
|---|---|---:|
| A. CRIU page-server 단독 실험 | CPU memory direct/lazy transfer 개념 확인 | 불필요 |
| B. GCR remote sink POC | GPU D2H staging chunk가 remote memory로 전송 가능한지 확인 | 불필요 |
| C. GCR+CRIUgpu 결합 실험 | remote sink 이후 CRIUgpu control checkpoint와 충돌 없는지 확인 | 선택 |
| D. Restore 결합 실험 | remote memory에 있는 GPU data로 H2D remap 가능한지 확인 | 선택 |

## 6. 실험 A: CRIU Page-server 단독 확인

이 실험은 GCR이 아니라 CRIU page-server 자체가 어떤 문제를 푸는지 확인하기 위한 기준선이다.

Receiver Host에서 page-server를 실행한다.

```bash
mkdir -p /dev/shm/criu-page-server-test
criu page-server \
  --images-dir /dev/shm/criu-page-server-test \
  --address 0.0.0.0 \
  --port 19091
```

Source Host에서 일반 CPU memory를 크게 잡는 프로세스를 실행한 뒤 CRIU dump를 수행한다.

```bash
mkdir -p /tmp/criu-page-source
python3 - <<'PY' &
import time
x = bytearray(1024 * 1024 * 1024)
for i in range(0, len(x), 4096):
    x[i] = 1
print("pid ready")
time.sleep(3600)
PY
PID=$!

criu dump \
  -t "$PID" \
  --images-dir /tmp/criu-page-source \
  --shell-job \
  --page-server \
  --address <receiver-ip> \
  --port 19091
```

이 단계의 목적은 CPU page-server 동작 확인이다. GPU data는 아직 대상이 아니다.

## 7. 실험 B: GCR Remote-memory Sink POC

이 단계가 실제로 필요한 본 실험이다. 목표는 `checkpoint_freeze()`에서 GPU memory를 host staging buffer로 가져온 직후, file-backed `g_blob`에 쓰는 대신 remote receiver로 직접 전송하는 것이다.

### 7.1 GCR interceptor에 추가할 최소 기능

`interceptor/preload.c`에 다음 개념을 추가한다.

| 설정 | 의미 |
|---|---|
| `GCR_BLOB_SINK=file` | 기존 방식. `data.blob` 파일 생성 |
| `GCR_BLOB_SINK=tcp` | GPU D2H chunk를 remote receiver로 직접 전송 |
| `GCR_REMOTE_HOST=<ip>` | remote receiver IP |
| `GCR_REMOTE_PORT=<port>` | remote receiver port |

POC의 핵심 변경은 다음과 같다.

```text
기존:
  cudaMemcpy D2H -> g_stage -> memcpy(g_blob + offset, g_stage, chunk)

POC:
  cudaMemcpy D2H -> g_stage -> send(socket, header + chunk)
```

전송 header에는 최소한 다음 정보가 필요하다.

| 필드 | 이유 |
|---|---|
| magic/version | receiver가 GCR stream인지 확인 |
| process id 또는 run id | 여러 checkpoint 구분 |
| segment index | 어떤 GPU allocation인지 구분 |
| original VA | restore 시 같은 VA remap 검증 |
| requested size | 실제 CUDA allocation 크기 |
| padded size | VMM granularity 반영 크기 |
| offset | blob 내 logical offset |
| chunk length | 수신 byte 수 검증 |
| checksum | chunk 무결성 확인 |

### 7.2 Receiver가 해야 할 일

Receiver는 수신 데이터를 디스크 파일이 아니라 memory에 보관해야 한다.

가능한 방식은 세 가지다.

| 방식 | 검증 강도 | 설명 |
|---|---:|---|
| process heap buffer | 높음 | receiver가 malloc/mmap anonymous memory에 segment를 보관 |
| `memfd_create` | 높음 | Linux memory-backed fd로 보관. file descriptor 기반 전달 가능 |
| `/dev/shm` 또는 tmpfs | 중간 | RAM-backed filesystem이지만 파일처럼 보임 |

가장 좋은 POC는 `memfd_create` 또는 anonymous `mmap` receiver다. `/dev/shm`은 구현은 쉽지만 "파일처럼 보이는 RAM-backed 저장소"라서 page-server와 완전히 같은 주장은 어렵다.

### 7.3 성공 기준

이 단계가 성공했다고 판단하려면 다음 증거가 필요하다.

| 증거 | 성공 기준 |
|---|---|
| Source 로그 | `freeze: N segs, X bytes -> remote memory sink` |
| Receiver 로그 | 동일한 segment 수와 byte 수 수신 |
| Checksum | Source chunk checksum과 Receiver checksum 일치 |
| Disk I/O | source의 `data.blob` 미생성 또는 0 byte |
| Remote memory | receiver RSS 또는 memfd/tmpfs 사용량 증가 |
| Workload 상태 | freeze 후 source process가 crash 없이 remap/resume 가능 |

## 8. 실험 C: GCR+CRIUgpu 결합 확인

실험 B가 성공하면 다음은 CRIUgpu와 같이 실행했을 때 문제가 없는지 확인한다.

검증 순서는 다음과 같다.

1. CUDA workload 실행
2. `GCR_BLOB_SINK=tcp`로 설정
3. Receiver 실행
4. GCR checkpoint signal 발생
5. GPU data는 receiver memory로 전송
6. Source process는 GPU physical memory release
7. CRIUgpu가 CPU/control state checkpoint
8. checkpoint tar에는 GPU data가 포함되지 않는지 확인

이 단계에서 확인해야 할 로그는 다음과 같다.

```text
[gcr][engine] freeze: ... -> remote memory sink
[gcr] checkpoint ACK sent
GPUCheckpoint phase=Completed
```

그리고 Source Host에서 다음을 확인한다.

```bash
ls -lh /var/lib/gcr-data/<podUID>/data.blob
```

직접 전송 POC에서는 이 파일이 없어야 하거나, fallback/debug 용도로만 생성되어야 한다.

## 9. 실험 D: Restore까지 검증하려면 필요한 것

직접 전송 가능성만 보려면 실험 B 또는 C까지면 충분하다. 하지만 Restore까지 검증하려면 target side가 remote memory에 있는 GPU data를 H2D로 다시 올릴 수 있어야 한다.

Restore까지 보려면 다음 기능 중 하나가 필요하다.

| 방식 | 설명 |
|---|---|
| Receiver가 `memfd`를 local path로 노출 | restore process가 해당 fd/path에서 읽어 H2D remap |
| Receiver가 local Unix socket으로 blob read API 제공 | restore runtime이 필요한 segment를 요청 |
| CRI-O restore patch에 `tcp://` 또는 `memfd://` data-uri 추가 | restore annotation이 remote memory source를 직접 가리킴 |
| tmpfs fallback | receiver가 `/dev/shm/.../data.blob`에 두고 restore가 hostPath로 읽음 |

단기 검증은 tmpfs fallback이 가장 쉽다. 하지만 논문/발표에서 "Page-server처럼 직접 memory transfer"라고 주장하려면 최종적으로는 `file sink`가 아니라 `network/memfd sink` 구현 증거가 필요하다.

## 10. 현재 포함된 스크립트의 위치

현재 repo에 있는 다음 스크립트는 본 실험의 최종 증명이 아니라 대조군이다.

```text
scripts/16-start-remote-memory-receiver.sh
scripts/17-send-latest-checkpoint-to-remote-memory.sh
```

이 스크립트는 이미 생성된 checkpoint `.tar`와 `.blob`을 원격 `/dev/shm`으로 보내는 실험이다. 즉 다음을 확인할 수 있다.

```text
완성된 artifact를 remote RAM-backed filesystem에 stage할 수 있는가?
```

하지만 다음을 확인하지는 못한다.

```text
GCR checkpoint 수행 중 GPU D2H staging data가 file sink 없이 곧바로 remote memory로 전송되는가?
```

따라서 본 검증을 위해서는 GCR checkpoint repo에 별도 브랜치를 만들고 `interceptor/preload.c`의 data sink를 확장하는 작업이 필요하다.

## 11. 권장 진행 순서

1. Kubernetes 없이 Source GPU Host와 Receiver Host를 정한다.
2. Receiver에 `memfd` 또는 anonymous memory 기반 receiver POC를 만든다.
3. GCR interceptor에 `GCR_BLOB_SINK=tcp` 옵션을 추가한다.
4. `checkpoint_freeze()`의 `g_stage -> g_blob` write 경로를 `g_stage -> socket send` 경로로 바꾼다.
5. source/receiver 양쪽에서 segment metadata, byte count, checksum을 기록한다.
6. `data.blob`을 만들지 않고도 checkpoint freeze가 끝나는지 확인한다.
7. 필요하면 CRIUgpu checkpoint까지 결합해서 CPU/control checkpoint와 충돌하지 않는지 확인한다.
8. Restore 검증은 별도 단계로 분리한다.

## 12. 판단 문장

실험 B가 성공하면 다음과 같이 말할 수 있다.

```text
GCR selective interception은 GPU allocation의 VA, size, VMM handle을 추적하고,
checkpoint 시점에 해당 GPU memory를 host staging buffer로 D2H copy한다.
따라서 file-backed external blob 대신 network sink를 붙이면 GPU checkpoint data를
다른 Host의 memory receiver로 직접 전송하는 것이 가능함을 확인하였다.
```

실험 C까지 성공하면 다음과 같이 말할 수 있다.

```text
GCR remote-memory sink와 CRIUgpu control checkpoint를 결합해도 checkpoint phase가 완료된다.
즉 GPU data path는 remote memory로 분리하고, CPU/control state는 CRIUgpu로 checkpoint하는
분리형 checkpoint 구조가 가능하다.
```

Restore까지 성공하지 않았다면 다음 표현은 피해야 한다.

```text
remote memory에서 바로 end-to-end restore까지 완료된다.
```

## 13. 참고 자료

- CRIU Page server: https://criu.org/Page_server
- CRIU lazy-pages command: https://www.criu.org/CLI/cmd/lazy-pages
- CRIU man page: https://manpages.debian.org/trixie/criu/criu.8.en.html
- NVIDIA CUDA checkpoint with CRIU: https://developer.nvidia.com/blog/checkpointing-cuda-applications-with-criu/
