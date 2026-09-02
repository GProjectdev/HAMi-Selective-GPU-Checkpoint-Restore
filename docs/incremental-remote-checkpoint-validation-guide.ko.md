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

## 12. 현재 수동 검증 실행 절차

이 절차는 아직 GCR interceptor에 incremental 전송 기능을 넣기 전, 이미 생성된 두 `.blob` 파일을 이용해 base/delta 방식이 실제로 성립하는지 확인하는 1차 검증이다.

검증 흐름은 다음과 같다.

```text
Worker Node:
  BASE blob과 NEXT blob 비교
  변경 chunk만 delta file로 추출
  BASE + delta로 rebuilt blob 생성
  rebuilt == NEXT 확인

Receiver Server:
  BASE blob과 delta file만 수신
  /dev/shm 또는 tmpfs에서 rebuilt blob 생성
  rebuilt == NEXT 확인
```

### 12.1 Master Node: checkpoint 대상과 source node 확인

Master Node에서 현재 inference Pod와 checkpoint 상태를 확인한다.

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore

kubectl -n hami-selective-cr get pod hami-infer-gpt2 -o wide
kubectl -n hami-selective-cr get gpucheckpoint -o wide

cat .state/last-inference-overhead-node 2>/dev/null || true
cat .state/last-inference-overhead-pod 2>/dev/null || true
cat .state/last-checkpoint-observed-node 2>/dev/null || true
cat .state/last-checkpoint-path 2>/dev/null || true
```

성공 기준:

```text
hami-infer-gpt2 Pod가 Running
checkpoint가 Completed
observedNode가 실제 Pod가 실행 중인 Worker Node와 일치
```

이후 `.blob` 비교와 delta rebuild는 checkpoint가 생성된 Worker Node에서 수행한다.

### 12.2 Worker Node: 비교할 BASE/NEXT blob 지정

Worker Node에서 checkpoint artifact가 있는 경로로 이동한다.

```bash
cd /var/lib/gcr-checkpoint
ls -lh checkpoint-hami-infer-gpt2_*.blob
```

최신 두 checkpoint blob을 직접 지정한다.

예시:

```bash
BASE=checkpoint-hami-infer-gpt2_hami-selective-cr-inference-1787919767.blob
NEXT=checkpoint-hami-infer-gpt2_hami-selective-cr-inference-1787919866.blob
CHUNK=$((2*1024*1024))
```

크기와 hash를 먼저 확인한다.

```bash
stat -c '%n %s bytes' "$BASE" "$NEXT"
sha256sum "$BASE" "$NEXT"
```

성공 기준:

```text
BASE/NEXT 파일이 모두 존재
두 파일 크기 확인 가능
```

### 12.3 Worker Node: 변경 chunk 추출

Worker Node에서 다음 명령을 실행한다.

```bash
cd /var/lib/gcr-checkpoint

OUT=/tmp/gcr-incremental-local-rebuild
rm -rf "$OUT"
mkdir -p "$OUT/delta"

cp "$BASE" "$OUT/rebuilt.blob"

python3 - "$BASE" "$NEXT" "$OUT" "$CHUNK" <<'PY'
import hashlib
import os
import sys

base_path, next_path, out_dir, chunk_s = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

manifest = os.path.join(out_dir, "delta-manifest.tsv")
changed = 0
unchanged = 0
changed_bytes = 0
total_chunks = 0

with open(base_path, "rb") as base, open(next_path, "rb") as nxt, open(manifest, "w") as mf:
    mf.write("chunk_index\toffset\tlength\tsha256\tfile\n")
    offset = 0
    chunk_index = 0

    while True:
        a = base.read(chunk_s)
        b = nxt.read(chunk_s)
        if not a and not b:
            break

        total_chunks += 1
        if hashlib.sha256(a).digest() == hashlib.sha256(b).digest():
            unchanged += 1
        else:
            changed += 1
            changed_bytes += len(b)
            delta_file = f"delta/chunk-{chunk_index:06d}.bin"
            delta_path = os.path.join(out_dir, delta_file)
            with open(delta_path, "wb") as df:
                df.write(b)
            mf.write(
                f"{chunk_index}\t{offset}\t{len(b)}\t"
                f"{hashlib.sha256(b).hexdigest()}\t{delta_file}\n"
            )

        offset += chunk_s
        chunk_index += 1

full_bytes = os.path.getsize(next_path)
delta_ratio = changed_bytes / full_bytes if full_bytes else 0

print(f"total_chunks={total_chunks}")
print(f"changed_chunks={changed}")
print(f"unchanged_chunks={unchanged}")
print(f"delta_bytes={changed_bytes}")
print(f"full_bytes={full_bytes}")
print(f"delta_ratio={delta_ratio:.6f}")
print(f"delta_reduction_percent={(1 - delta_ratio) * 100:.3f}")
print(f"manifest={manifest}")
PY
```

성공 기준:

```text
changed_chunks가 출력됨
delta_bytes가 full_bytes보다 작음
delta-manifest.tsv와 delta/chunk-*.bin 파일 생성
```

예시 성공 결과:

```text
total_chunks=145
changed_chunks=3
unchanged_chunks=142
delta_bytes=6291456
full_bytes=304087040
delta_ratio=0.020690
delta_reduction_percent=97.931
```

### 12.4 Worker Node: local rebuilt blob 생성 및 검증

Worker Node에서 BASE에 delta를 적용한다.

```bash
python3 - "$OUT/rebuilt.blob" "$OUT/delta-manifest.tsv" "$OUT" <<'PY'
import hashlib
import os
import sys

rebuilt_path, manifest_path, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]

with open(rebuilt_path, "r+b") as rebuilt, open(manifest_path, "r") as mf:
    next(mf)
    for line in mf:
        chunk_index, offset, length, expected_sha, rel_file = line.rstrip("\n").split("\t")
        offset = int(offset)
        length = int(length)
        delta_path = os.path.join(out_dir, rel_file)

        with open(delta_path, "rb") as df:
            data = df.read()

        actual_sha = hashlib.sha256(data).hexdigest()
        if actual_sha != expected_sha:
            raise SystemExit(f"delta checksum mismatch: {delta_path}")

        if len(data) != length:
            raise SystemExit(f"delta length mismatch: {delta_path}")

        rebuilt.seek(offset)
        rebuilt.write(data)

print("delta_applied=true")
PY

sha256sum "$NEXT" "$OUT/rebuilt.blob"
du -sh "$OUT/delta"
cat "$OUT/delta-manifest.tsv"
```

성공 기준:

```text
sha256sum "$NEXT" "$OUT/rebuilt.blob" 결과의 hash가 동일
delta directory 크기가 full blob보다 작음
```

이 단계가 성공하면 다음을 주장할 수 있다.

```text
BASE blob + 변경 chunk만으로 NEXT blob을 정확히 재구성할 수 있다.
```

### 12.5 Receiver Server: tmpfs 준비

Receiver Server, 현재 환경에서는 `10.178.0.14`, 에서 memory-backed 경로를 준비한다.

```bash
df -h /dev/shm
free -h

RUN_ID=gpt2-incremental-$(date -u +%Y%m%dT%H%M%SZ)
REMOTE_DIR=/dev/shm/gcr-incremental/${RUN_ID}

mkdir -p "$REMOTE_DIR"
echo "$REMOTE_DIR"
```

성공 기준:

```text
/dev/shm에 full BASE blob과 delta를 둘 공간이 있음
REMOTE_DIR가 생성됨
```

gpt2 기준으로는 BASE blob이 약 290MiB이고 delta가 약 6MiB였으므로, `/dev/shm` 여유 공간이 수 GB라면 충분하다.

### 12.6 Worker Node: BASE와 delta만 Receiver tmpfs로 전송

Worker Node에서 실행한다.

```bash
REMOTE=root@10.178.0.14
RUN_ID=gpt2-incremental-$(date -u +%Y%m%dT%H%M%SZ)
REMOTE_DIR=/dev/shm/gcr-incremental/${RUN_ID}

ssh "$REMOTE" "mkdir -p '$REMOTE_DIR'"

scp "$BASE" "$REMOTE:$REMOTE_DIR/base.blob"
scp "$OUT/delta-manifest.tsv" "$REMOTE:$REMOTE_DIR/delta-manifest.tsv"
scp -r "$OUT/delta" "$REMOTE:$REMOTE_DIR/delta"

sha256sum "$NEXT" > "$OUT/next.sha256"
scp "$OUT/next.sha256" "$REMOTE:$REMOTE_DIR/next.sha256"

echo "$REMOTE_DIR"
```

여기서 전송되는 것은 `NEXT` full blob이 아니다.

전송되는 파일:

```text
base.blob
delta-manifest.tsv
delta/chunk-*.bin
next.sha256
```

`next.sha256`은 검증용 hash 파일이다. 실제 incremental 시스템에서는 receiver가 최종 hash를 계산하고 control plane에 보고하면 된다.

성공 기준:

```text
scp 실패 없음
receiver의 REMOTE_DIR에 base.blob, delta-manifest.tsv, delta/가 존재
```

### 12.7 Receiver Server: tmpfs에서 rebuilt blob 생성

Receiver Server에서 `REMOTE_DIR`를 위에서 출력된 값으로 설정한 뒤 실행한다.

```bash
set -Eeuo pipefail

# 12.6에서 마지막에 출력된 값을 그대로 넣는다.
# 예:
# REMOTE_DIR=/dev/shm/gcr-incremental/gpt2-incremental-20260828T124750Z
: "${REMOTE_DIR:?REMOTE_DIR must be set to the directory printed by step 12.6}"

cd "$REMOTE_DIR"

test -f base.blob
test -f delta-manifest.tsv
test -f next.sha256
test -d delta
ls -lh
ls -lh delta

cp base.blob rebuilt.blob

python3 - rebuilt.blob delta-manifest.tsv . <<'PY'
import hashlib
import os
import sys

rebuilt_path, manifest_path, root_dir = sys.argv[1], sys.argv[2], sys.argv[3]

with open(rebuilt_path, "r+b") as rebuilt, open(manifest_path, "r") as mf:
    next(mf)
    for line in mf:
        chunk_index, offset, length, expected_sha, rel_file = line.rstrip("\n").split("\t")
        offset = int(offset)
        length = int(length)
        delta_path = os.path.join(root_dir, rel_file)

        with open(delta_path, "rb") as df:
            data = df.read()

        actual_sha = hashlib.sha256(data).hexdigest()
        if actual_sha != expected_sha:
            raise SystemExit(f"delta checksum mismatch: {delta_path}")

        if len(data) != length:
            raise SystemExit(f"delta length mismatch: {delta_path}")

        rebuilt.seek(offset)
        rebuilt.write(data)

print("remote_delta_applied=true")
PY

sha256sum rebuilt.blob
cat next.sha256

test "$(sha256sum rebuilt.blob | awk '{print $1}')" = "$(awk '{print $1}' next.sha256)"
echo "remote_rebuild_verified=true"

du -sh .
du -sh delta
ls -lh
```

성공 기준:

```text
remote_rebuild_verified=true 출력
rebuilt.blob hash == NEXT blob hash
delta 크기만큼만 변경분 전송
```

이 단계가 성공하면 다음을 주장할 수 있다.

```text
Remote Server의 tmpfs에 BASE checkpoint GPU data를 유지하고,
변경 delta chunk만 전송하여 NEXT checkpoint GPU data blob을 정확히 재구성할 수 있다.
```

### 12.8 결과를 보여줄 때 필요한 출력

오류 분석 또는 보고서 정리를 위해 다음 출력만 보여주면 된다.

Worker Node:

```bash
cat /tmp/gcr-incremental-local-rebuild/delta-manifest.tsv
sha256sum "$NEXT" /tmp/gcr-incremental-local-rebuild/rebuilt.blob
du -sh /tmp/gcr-incremental-local-rebuild/delta
ls -lh /tmp/gcr-incremental-local-rebuild/delta
```

Receiver Server:

```bash
cd "$REMOTE_DIR"
sha256sum rebuilt.blob
cat next.sha256
du -sh .
du -sh delta
ls -lh
```

### 12.9 실패 시 판단 기준

| 증상 | 의미 | 확인할 것 |
|---|---|---|
| `No such file or directory` | BASE/NEXT/OUT/REMOTE_DIR 경로 불일치 | 변수 값 echo, `ls -lh` |
| `delta checksum mismatch` | delta 파일 손상 또는 잘못된 manifest 사용 | `sha256sum delta/chunk-*`, manifest |
| rebuilt hash 불일치 | offset/length 적용 오류 또는 다른 NEXT 기준 사용 | BASE/NEXT 파일명, manifest 생성 시점 |
| `/dev/shm` 용량 부족 | receiver tmpfs 공간 부족 | `df -h /dev/shm`, 더 작은 모델/저장소 사용 |
| `scp` 실패 | SSH 권한/네트워크 문제 | `ssh root@10.178.0.14 hostname` |

## 13. 다음 자동화 구현 방향

수동 검증이 끝나면 다음 순서로 자동화한다.

```text
1. Worker에서 BASE/NEXT blob 비교와 delta manifest 생성을 스크립트화
2. Receiver tmpfs 전송과 remote rebuild를 스크립트화
3. Python TCP sender/receiver로 file-copy가 아닌 stream 방식 검증
4. GCR interceptor에 hash-diff incremental mode 추가
5. receiver가 delta stream을 즉시 base snapshot에 적용하도록 구현
6. rebuilt .blob을 기존 .tar/.restore.json/.hami-runtime.tar와 합쳐 restore 검증
```

자동화 스크립트 후보:

```text
scripts/19-compare-checkpoint-blob-delta.sh
scripts/20-run-remote-tmpfs-delta-rebuild.sh
scripts/21-start-incremental-remote-receiver.sh
scripts/22-send-incremental-delta-stream.sh
scripts/23-summarize-incremental-checkpoint-results.sh
```

## 14. 단계별 주장 가능 범위

### 14.1 Local delta rebuild 성공 후

```text
연속 checkpoint의 GPU data blob을 비교한 결과,
전체 blob 중 일부 chunk만 변경되었고,
BASE blob에 delta chunk만 적용해 NEXT blob을 정확히 재구성할 수 있음을 확인했다.
```

### 14.2 Remote tmpfs delta rebuild 성공 후

```text
Remote Server memory-backed tmpfs에 BASE blob을 유지하고,
변경 delta chunk만 전송하여 NEXT checkpoint GPU data blob을 재구성할 수 있음을 확인했다.
```

### 14.3 TCP delta stream 성공 후

```text
checkpoint GPU data delta를 파일 복사가 아니라 stream 형태로 remote receiver에 전송하고,
receiver가 memory snapshot에 즉시 반영할 수 있음을 확인했다.
```

### 14.4 Restore 성공 후

```text
delta 기반으로 remote에서 재구성한 GPU data blob이 실제 restore에 사용 가능함을 확인했다.
```

## 15. 최종적으로 주장할 수 있는 범위

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

## 16. 참고 자료

```text
https://www.usenix.org/conference/fast26/presentation/zeng
https://github.com/thustorage/GCR
https://criu.org/Page_server
```

## 17. VM 재시작 후 재진행 가이드

VM을 껐다 켠 뒤에는 이전 shell 변수와 Receiver Server의 `/dev/shm` 내용이 사라졌다고 가정하고 다시 진행한다. 특히 `/dev/shm`은 tmpfs이므로 재부팅 후 비워질 수 있다. 따라서 이전에 출력된 `REMOTE_DIR`만 믿고 바로 `cd "$REMOTE_DIR"`를 하면 빈 디렉터리에서 검증을 실행하게 될 수 있다.

이 섹션은 재시작 후 이 절차만 보고 다시 검증할 수 있도록 정리한 실행 순서이다.

### 17.1 전체 흐름

```text
1. Master Node에서 현재 inference Pod와 checkpoint 상태 확인
2. 실제 checkpoint blob이 있는 Worker Node 확인
3. Worker Node에서 BASE/NEXT blob 재지정
4. Worker Node에서 delta 재생성
5. Worker Node에서 local rebuild 검증
6. Receiver Server의 /dev/shm에 새 REMOTE_DIR 생성
7. Worker Node에서 BASE + delta + next.sha256 전송
8. Receiver Server에서 remote rebuild 검증
```

성공 기준은 다음 하나이다.

```text
remote_rebuild_verified=true
```

### 17.2 Master Node: 현재 상태 확인

Master Node에서 실행한다.

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore

kubectl -n hami-selective-cr get pod -o wide
kubectl -n hami-selective-cr get gpucheckpoint -o wide

kubectl -n hami-selective-cr get gpucheckpoint hami-infer-gpt2-checkpoint -o yaml | \
  grep -E 'observedNode|podUID|lastCheckpointPath|phase'
```

확인할 것:

```text
hami-infer-gpt2가 Running인지
GPUCheckpoint가 Completed인지
observedNode가 어느 Worker Node인지
lastCheckpointPath가 어떤 tar 파일인지
```

`observedNode`에 나온 Worker Node로 접속해서 다음 단계를 진행한다.

### 17.3 Worker Node: checkpoint blob 재확인

checkpoint가 생성된 Worker Node에서 실행한다.

```bash
cd /var/lib/gcr-checkpoint
ls -lh checkpoint-hami-infer-gpt2_*.blob
```

최신 두 개를 BASE/NEXT로 잡는다. 오래된 것을 BASE, 더 최신 것을 NEXT로 둔다.

```bash
BASE=$(ls -t checkpoint-hami-infer-gpt2_*.blob | sed -n '2p')
NEXT=$(ls -t checkpoint-hami-infer-gpt2_*.blob | sed -n '1p')
CHUNK=$((2*1024*1024))

echo "BASE=$BASE"
echo "NEXT=$NEXT"
stat -c '%n %s bytes' "$BASE" "$NEXT"
sha256sum "$BASE" "$NEXT"
```

주의:

```text
BASE와 NEXT가 비어 있으면 checkpoint blob이 2개 이상 없는 것이다.
이 경우 gpt2 Pod에서 checkpoint를 한 번 더 수행한 뒤 다시 확인한다.
```

### 17.4 Worker Node: delta 재생성

Worker Node에서 실행한다.

```bash
set -Eeuo pipefail

cd /var/lib/gcr-checkpoint

: "${BASE:?BASE is not set}"
: "${NEXT:?NEXT is not set}"
: "${CHUNK:?CHUNK is not set}"

OUT=/tmp/gcr-incremental-local-rebuild
rm -rf "$OUT"
mkdir -p "$OUT/delta"

cp "$BASE" "$OUT/rebuilt.blob"

python3 - "$BASE" "$NEXT" "$OUT" "$CHUNK" <<'PY'
import hashlib
import os
import sys

base_path, next_path, out_dir, chunk_s = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

manifest = os.path.join(out_dir, "delta-manifest.tsv")
changed = 0
unchanged = 0
changed_bytes = 0
total_chunks = 0

with open(base_path, "rb") as base, open(next_path, "rb") as nxt, open(manifest, "w") as mf:
    mf.write("chunk_index\toffset\tlength\tsha256\tfile\n")
    offset = 0
    chunk_index = 0

    while True:
        a = base.read(chunk_s)
        b = nxt.read(chunk_s)
        if not a and not b:
            break

        total_chunks += 1
        if hashlib.sha256(a).digest() == hashlib.sha256(b).digest():
            unchanged += 1
        else:
            changed += 1
            changed_bytes += len(b)
            delta_file = f"delta/chunk-{chunk_index:06d}.bin"
            delta_path = os.path.join(out_dir, delta_file)
            with open(delta_path, "wb") as df:
                df.write(b)
            mf.write(
                f"{chunk_index}\t{offset}\t{len(b)}\t"
                f"{hashlib.sha256(b).hexdigest()}\t{delta_file}\n"
            )

        offset += chunk_s
        chunk_index += 1

full_bytes = os.path.getsize(next_path)
delta_ratio = changed_bytes / full_bytes if full_bytes else 0

print(f"total_chunks={total_chunks}")
print(f"changed_chunks={changed}")
print(f"unchanged_chunks={unchanged}")
print(f"delta_bytes={changed_bytes}")
print(f"full_bytes={full_bytes}")
print(f"delta_ratio={delta_ratio:.6f}")
print(f"delta_reduction_percent={(1 - delta_ratio) * 100:.3f}")
print(f"manifest={manifest}")
PY
```

### 17.5 Worker Node: local rebuild 검증

Worker Node에서 실행한다.

```bash
python3 - "$OUT/rebuilt.blob" "$OUT/delta-manifest.tsv" "$OUT" <<'PY'
import hashlib
import os
import sys

rebuilt_path, manifest_path, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]

with open(rebuilt_path, "r+b") as rebuilt, open(manifest_path, "r") as mf:
    next(mf)
    for line in mf:
        chunk_index, offset, length, expected_sha, rel_file = line.rstrip("\n").split("\t")
        offset = int(offset)
        length = int(length)
        delta_path = os.path.join(out_dir, rel_file)

        with open(delta_path, "rb") as df:
            data = df.read()

        actual_sha = hashlib.sha256(data).hexdigest()
        if actual_sha != expected_sha:
            raise SystemExit(f"delta checksum mismatch: {delta_path}")
        if len(data) != length:
            raise SystemExit(f"delta length mismatch: {delta_path}")

        rebuilt.seek(offset)
        rebuilt.write(data)

print("local_delta_applied=true")
PY

sha256sum "$NEXT" "$OUT/rebuilt.blob"
test "$(sha256sum "$NEXT" | awk '{print $1}')" = "$(sha256sum "$OUT/rebuilt.blob" | awk '{print $1}')"
echo "local_rebuild_verified=true"

cat "$OUT/delta-manifest.tsv"
du -sh "$OUT/delta"
ls -lh "$OUT/delta"
```

`local_rebuild_verified=true`가 나오지 않으면 remote 전송 단계로 가지 않는다.

### 17.6 Worker Node: Receiver tmpfs로 재전송

Worker Node에서 실행한다. 재부팅 후에는 이전 `REMOTE_DIR`를 재사용하지 말고 새로 만든다.

```bash
set -Eeuo pipefail

REMOTE=root@10.178.0.14
RUN_ID=gpt2-incremental-$(date -u +%Y%m%dT%H%M%SZ)
REMOTE_DIR=/dev/shm/gcr-incremental/${RUN_ID}

ssh "$REMOTE" "mkdir -p '$REMOTE_DIR' && df -h /dev/shm && ls -ld '$REMOTE_DIR'"

scp "$BASE" "$REMOTE:$REMOTE_DIR/base.blob"
scp "$OUT/delta-manifest.tsv" "$REMOTE:$REMOTE_DIR/delta-manifest.tsv"
scp -r "$OUT/delta" "$REMOTE:$REMOTE_DIR/delta"

sha256sum "$NEXT" > "$OUT/next.sha256"
scp "$OUT/next.sha256" "$REMOTE:$REMOTE_DIR/next.sha256"

echo "REMOTE_DIR=$REMOTE_DIR"
```

이 단계가 성공하면 마지막 줄의 `REMOTE_DIR=...` 값을 복사해 둔다.

### 17.7 Receiver Server: remote rebuild 검증

Receiver Server, 즉 `10.178.0.14`, 에서 실행한다. `REMOTE_DIR`는 17.6 마지막에 출력된 값을 그대로 넣는다.

```bash
set -Eeuo pipefail

# 17.6에서 출력된 값으로 바꾼다.
REMOTE_DIR=/dev/shm/gcr-incremental/gpt2-incremental-20260829T051000Z

cd "$REMOTE_DIR"

test -f base.blob
test -f delta-manifest.tsv
test -f next.sha256
test -d delta

ls -lh
ls -lh delta

cp base.blob rebuilt.blob

python3 - rebuilt.blob delta-manifest.tsv . <<'PY'
import hashlib
import os
import sys

rebuilt_path, manifest_path, root_dir = sys.argv[1], sys.argv[2], sys.argv[3]

with open(rebuilt_path, "r+b") as rebuilt, open(manifest_path, "r") as mf:
    next(mf)
    for line in mf:
        chunk_index, offset, length, expected_sha, rel_file = line.rstrip("\n").split("\t")
        offset = int(offset)
        length = int(length)
        delta_path = os.path.join(root_dir, rel_file)

        with open(delta_path, "rb") as df:
            data = df.read()

        actual_sha = hashlib.sha256(data).hexdigest()
        if actual_sha != expected_sha:
            raise SystemExit(f"delta checksum mismatch: {delta_path}")
        if len(data) != length:
            raise SystemExit(f"delta length mismatch: {delta_path}")

        rebuilt.seek(offset)
        rebuilt.write(data)

print("remote_delta_applied=true")
PY

sha256sum rebuilt.blob
cat next.sha256

test "$(sha256sum rebuilt.blob | awk '{print $1}')" = "$(awk '{print $1}' next.sha256)"
echo "remote_rebuild_verified=true"

du -sh .
du -sh delta
ls -lh
```

성공하면 다음이 출력된다.

```text
remote_delta_applied=true
remote_rebuild_verified=true
```

### 17.8 이번에 보여주면 되는 출력

오류가 나면 전체 로그보다 아래 출력만 먼저 보여주면 된다.

Master Node:

```bash
kubectl -n hami-selective-cr get pod -o wide
kubectl -n hami-selective-cr get gpucheckpoint -o wide
```

Worker Node:

```bash
echo "BASE=$BASE"
echo "NEXT=$NEXT"
sha256sum "$NEXT" "$OUT/rebuilt.blob"
cat "$OUT/delta-manifest.tsv"
du -sh "$OUT/delta"
```

Receiver Server:

```bash
echo "$REMOTE_DIR"
ls -lh "$REMOTE_DIR"
ls -lh "$REMOTE_DIR/delta"
sha256sum "$REMOTE_DIR/rebuilt.blob"
cat "$REMOTE_DIR/next.sha256"
df -h /dev/shm
```

### 17.9 주의 사항

- `/dev/shm`은 재부팅 후 유지되는 저장소가 아니다. VM을 껐다 켜면 Receiver의 이전 `base.blob`, `delta`, `rebuilt.blob`은 없다고 보는 것이 안전하다.
- `REMOTE_DIR`는 Worker에서 `scp`한 디렉터리와 Receiver에서 `cd`하는 디렉터리가 반드시 같아야 한다.
- `remote_rebuild_verified=true`는 `test`가 통과한 뒤에만 의미가 있다. `set -Eeuo pipefail` 없이 실행하면 중간 실패 후에도 echo가 실행될 수 있으므로 반드시 포함한다.
- `BASE`와 `NEXT`는 같은 workload의 연속 checkpoint blob이어야 한다.
- `NEXT` 전체 파일은 Remote에 전송하지 않는다. `next.sha256`만 검증용으로 전송한다.
