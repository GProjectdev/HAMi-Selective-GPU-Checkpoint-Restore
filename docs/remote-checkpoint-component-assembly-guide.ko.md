# Remote Checkpoint Component Assembly 검증 가이드

이 문서는 GCR+CRIUgpu 기반 GPU checkpoint 결과를 `.tar` 파일 하나로만 옮기는 대신, checkpoint 내부 구성요소를 파일 단위로 receiver server의 tmpfs 또는 저장소에 전달하고, receiver 쪽에서 다시 checkpoint artifact를 조립할 수 있는지 검증하기 위한 절차이다.

## 1. 검증 목적

이번 검증의 핵심 질문은 다음과 같다.

```text
Checkpoint에 필요한 데이터는 반드시 source worker에서 완성된 .tar 파일 하나로 전송해야 하는가?
아니면 checkpoint 구성요소를 분리해서 remote server에 전달한 뒤,
remote server에서 다시 restore 가능한 artifact 형태로 조립할 수 있는가?
```

이를 위해 검증을 세 단계로 나눈다.

1. **1차 검증: component 단위 전송 가능성**
   Source Worker에서 checkpoint archive를 통째로 복사하지 않고, 내부 구성 파일을 receiver storage에 파일 단위로 재현할 수 있는지 확인한다.

2. **2차 검증: receiver storage 재현 및 무결성**
   Receiver storage에 생성된 `components/`, `gcr-data/`, `hami-vgpu-cache/` 구조가 유효하고, `SHA256SUMS` 검증이 통과하는지 확인한다.

3. **3차 검증: receiver-side checkpoint tar 조립**
   Receiver storage의 `components/` 디렉터리를 이용해 `rebuilt-*.tar` checkpoint archive를 다시 만들 수 있는지 확인한다.

## 2. 이 검증으로 확인하는 것과 아닌 것

이 검증으로 확인하는 것은 다음과 같다.

```text
Checkpoint artifact는 논리적으로 여러 구성 파일의 집합이다.
따라서 완성된 source .tar 파일 하나를 그대로 전송하지 않아도,
receiver server에 같은 구성 파일 구조를 재현하고,
receiver server에서 다시 .tar checkpoint archive를 조립할 수 있다.
```

이미 별도로 수행한 GPU memory remote sink 실험과 연결하면 다음과 같이 해석할 수 있다.

```text
GPU memory payload:
GCR interceptor가 checkpoint 중 remote memory receiver로 직접 전송 가능함을 확인했다.

CRIU/CRI-O checkpoint 구성요소:
파일 단위로 receiver storage에 재현하고 checksum으로 무결성을 확인할 수 있다.

최종 artifact:
receiver storage에서 components/를 다시 .tar로 조립하고,
GCR .blob과 HAMi cache를 별도 구성요소로 유지할 수 있다.
```

다만 이 검증이 의미하지 않는 것도 명확히 해야 한다.

```text
이 스크립트는 현재 CRI-O가 이미 source node에서 만든 checkpoint tar를 입력으로 사용한다.
즉, source node에서 tar 생성 자체를 완전히 제거했다는 뜻은 아니다.
```

source-side tar 생성을 완전히 제거하려면 CRI-O checkpoint 경로에서 CRIU dump output directory를 바로 remote sender로 넘기거나, CRIU page-server와 GCR remote sink를 하나의 receiver protocol로 묶는 추가 구현이 필요하다.

## 3. 전체 구조

검증 구조는 다음과 같다.

```text
Source Worker
  ├─ 기존 CRI-O/GCR checkpoint 수행
  ├─ checkpoint .tar와 .blob 생성
  └─ helper Pod가 .tar를 내부 파일로 전개
        ↓
Receiver Storage, 예: NFS 또는 tmpfs-backed path
  ├─ components/
  │  ├─ spec.dump
  │  ├─ config.dump
  │  ├─ dump.log
  │  ├─ bind.mounts
  │  ├─ rootfs-diff.tar
  │  └─ checkpoint/*.img
  │
  ├─ gcr-data/
  │  └─ checkpoint-....blob
  │
  ├─ hami-vgpu-cache/
  │  └─ *.cache
  │
  ├─ SHA256SUMS
  ├─ FILE_MANIFEST.tsv
  └─ rebuilt-checkpoint-....tar
```

여기서 `.tar`와 `.blob`은 분리해서 다룬다.

```text
.tar:
CRIU/CRI-O가 관리하는 process state, CPU memory page, fd, mount, cgroup, seccomp, rootfs diff, OCI spec/config 등을 담는 checkpoint archive

.blob:
GCR/CRIUgpu 경로가 분리한 GPU memory payload
```

## 4. 노드별 역할

### Master Node

Master Node는 Kubernetes 명령을 실행하는 제어 노드이다.

Master Node에서 수행하는 일:

- inference workload 배포
- GPUCheckpoint 실행
- `.state/last-checkpoint-*` 상태 확인
- component assembly 검증 스크립트 실행
- 결과 로그 수집

### Source Worker

Source Worker는 checkpoint 대상 Pod가 실제로 실행되는 GPU worker node이다.

Source Worker에서 존재해야 하는 것:

- checkpoint `.tar`
- GCR `.blob`
- HAMi vGPU cache
- GCR/CRIUgpu/HAMi runtime

### Receiver Server

Receiver Server는 checkpoint 구성요소를 수신하고 보관하는 서버이다. 현재 실험에서는 `10.178.0.14:/mnt/nfs`를 receiver storage로 사용한다.

Receiver Server에서 확인할 것:

- `components/`가 생성되었는지
- `gcr-data/*.blob`이 생성되었는지
- `hami-vgpu-cache/`가 생성되었는지
- `SHA256SUMS`가 존재하는지
- `rebuilt-*.tar`가 생성되었는지

## 5. 사전 준비

Master Node에서 repository를 최신화한다.

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore
git pull
```

NFS 설정을 확인한다.

```bash
grep -E '^(NFS_SERVER|NFS_EXPORT_PATH|NFS_ARTIFACT_SUBDIR|TARGET_NODE)=' config/experiment.env
```

예상 값:

```text
NFS_SERVER=10.178.0.14
NFS_EXPORT_PATH=/mnt/nfs
NFS_ARTIFACT_SUBDIR=gcr_lastmonth/hami-selective-cr
```

현재 inference Pod 위치를 확인한다.

```bash
kubectl -n hami-selective-cr get pod hami-infer-gpt2 -o wide
```

예상 상태:

```text
hami-infer-gpt2   1/1   Running   ...   jsj-worker-*
```

## 6. 최신 checkpoint state 만들기

이 검증은 `.state/last-checkpoint-*` 값을 기준으로 source node와 checkpoint 파일을 찾는다. 따라서 현재 실행 중인 `hami-infer-gpt2`에 대해 checkpoint를 한 번 수행해서 state를 최신화해야 한다.

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore

bash ./scripts/14-run-checkpoint-overhead-benchmark.sh \
  --model gpt2 \
  --baseline-seconds 30 \
  --post-seconds 30 \
  --sample-interval-seconds 2 \
  --repeat 1 \
  --yes
```

실행 후 state를 확인한다.

```bash
printf 'node=%s\n' "$(cat .state/last-checkpoint-observed-node)"
printf 'path=%s\n' "$(cat .state/last-checkpoint-path)"
printf 'pod_uid=%s\n' "$(cat .state/last-checkpoint-source-pod-uid)"
printf 'container=%s\n' "$(cat .state/last-checkpoint-container)"
```

예상 결과:

```text
node=jsj-worker-2
path=/var/lib/gcr-checkpoint/checkpoint-hami-infer-gpt2_hami-selective-cr-inference-....tar
pod_uid=<hami-infer-gpt2 Pod UID>
container=inference
```

만약 `path`가 `checkpoint-hami-pod-a...`로 나오면 예전 selective Pod A checkpoint를 보고 있는 것이다. 이 경우 `14-run-checkpoint-overhead-benchmark.sh`를 다시 실행하거나, 현재 `hami-infer-gpt2-checkpoint`에서 state를 수동 갱신한다.

```bash
kubectl -n hami-selective-cr get gpucheckpoint hami-infer-gpt2-checkpoint -o jsonpath='{.status.lastCheckpointPath}' > .state/last-checkpoint-path
kubectl -n hami-selective-cr get gpucheckpoint hami-infer-gpt2-checkpoint -o jsonpath='{.status.podUID}' > .state/last-checkpoint-source-pod-uid
kubectl -n hami-selective-cr get gpucheckpoint hami-infer-gpt2-checkpoint -o jsonpath='{.status.observedNode}' > .state/last-checkpoint-observed-node
echo inference > .state/last-checkpoint-container
```

## 7. GPU Data Buffer remote memory(tmpfs) 검증

Component assembly 검증 전에, GPU memory data buffer가 실제로 remote server memory에 도착하는지도 함께 확인할 수 있다. 이 검증은 `.blob` 파일을 복사하는 실험이 아니라, GCR interceptor가 checkpoint 중 GPU memory를 host staging buffer로 D2H copy한 직후 그 chunk를 remote TCP receiver로 보내는지 확인하는 실험이다.

구조는 다음과 같다.

```text
Source Worker
  GPU memory
    ↓ D2H copy
  GCR host staging buffer
    ├─ 기존 local data.blob
    └─ remote TCP receiver, 예: 10.178.0.14:19092

Receiver Server
  Python receiver process memory
  summary file: /dev/shm/gcr-gpt2-remote-summary.env
```

Receiver server, 예: `10.178.0.14`, 에서 receiver를 먼저 실행한다.

```bash
cd ~/K8s-Native-Fast-GPU-Checkpoint-Restore-System

python3 tools/gcr_remote_memory_receiver.py \
  --host 0.0.0.0 \
  --port 19092 \
  --summary /dev/shm/gcr-gpt2-remote-summary.env \
  --hold-seconds 300
```

`/dev/shm`은 tmpfs이므로 receiver summary file은 disk가 아니라 memory-backed filesystem에 기록된다. 수신 payload 자체도 receiver process memory에 유지된다.

Receiver server에서 tmpfs 크기를 확인하려면 다음을 실행한다.

```bash
df -h /dev/shm
free -h
```

Source Worker에는 remote sink가 포함된 GCR interceptor가 설치되어 있어야 한다.

```bash
cd ~/K8s-Native-Fast-GPU-Checkpoint-Restore-System
git switch feature/gcr-remote-memory-sink
make -C interceptor clean all
sudo install -m 0755 interceptor/libgcr-interceptor.so /var/lib/gpu-cr/lib/libgcr-interceptor.so
```

Kubernetes DaemonSet이 interceptor를 다시 덮어쓰는 구조라면, node-agent image도 같은 브랜치 기준으로 다시 빌드/배포해야 한다.

Master Node에서 gpt2 inference Pod를 remote sink 활성화 상태로 배포한다.

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore

GCR_REMOTE_SINK=tcp-mirror \
GCR_REMOTE_HOST=10.178.0.14 \
GCR_REMOTE_PORT=19092 \
GCR_REMOTE_REQUIRED=false \
bash ./scripts/13-deploy-inference-overhead-workload.sh \
  --model gpt2 \
  --yes
```

그 다음 checkpoint를 1회 수행한다.

```bash
bash ./scripts/14-run-checkpoint-overhead-benchmark.sh \
  --model gpt2 \
  --baseline-seconds 60 \
  --post-seconds 60 \
  --sample-interval-seconds 2 \
  --repeat 1 \
  --yes
```

성공 기준은 다음과 같다.

Source Pod 로그:

```bash
kubectl -n hami-selective-cr logs hami-infer-gpt2 --tail=200 | grep -E 'gcr.*remote|gcr.*freeze'
```

예상 로그:

```text
[gcr][remote] connected sink=tcp-mirror 10.178.0.14:19092
[gcr][remote] sent <bytes> bytes in <chunks> chunks fnv64=0x...
[gcr][engine] freeze: <segs> segs, <bytes> bytes -> external blob
```

Receiver server 로그:

```text
begin expected_total_bytes=<bytes> advertised_segments=<segments>
end sender_chunks=<chunks> sender_bytes=<bytes> received_chunks=<chunks> received_bytes=<bytes> ... fnv64=0x... sender_fnv64=0x...
```

Receiver summary 확인:

```bash
cat /dev/shm/gcr-gpt2-remote-summary.env
```

성공 판단은 다음 조건을 모두 만족해야 한다.

```text
1. receiver가 source worker 연결을 accepted 한다.
2. sender_bytes와 received_bytes가 동일하다.
3. sender_chunks와 received_chunks가 동일하다.
4. receiver fnv64와 sender_fnv64가 동일하다.
5. hami-infer-gpt2 Pod가 checkpoint 후에도 Running 상태를 유지한다.
```

실제 성공 예시는 다음과 같다.

```text
expected_total_bytes=304087040
advertised_segments=19
sender_chunks=19
sender_bytes=304087040
received_chunks=19
received_bytes=304087040
duration_s=38.122120
throughput_mib_s=7.607
fnv64=0x64b15facd6cc6a0e
sender_fnv64=0x64b15facd6cc6a0e
rss_mib=358.2
```

이 결과는 다음을 의미한다.

```text
GCR selective interception이 잡은 GPU memory data buffer가 checkpoint 중 remote server의 memory-resident receiver로 전송되었고,
송신 byte 수와 수신 byte 수, 송신 checksum과 수신 checksum이 일치했다.
따라서 GPU memory payload는 local .blob 파일로만 남기는 것이 아니라 remote server memory로도 직접 보낼 수 있다.
```

주의할 점은 현재 모드가 `tcp-mirror`라는 것이다.

```text
현재 검증:
GPU memory data buffer를 remote memory receiver로 보내면서 기존 local .blob도 유지한다.

아직 검증하지 않은 것:
local .blob 없이 remote memory만으로 restore까지 수행하는 end-to-end 경로
```

따라서 이 섹션은 “GPU Data Buffer를 remote server memory/tmpfs 기반 receiver로 보낼 수 있는가?”에 대한 검증이고, 다음 섹션은 “그 외 checkpoint 구성 파일을 receiver storage에 재현하고 tar로 조립할 수 있는가?”에 대한 검증이다.

## 8. 1/2/3차 검증 실행

Master Node에서 다음을 실행한다.

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore

bash ./scripts/18-validate-remote-checkpoint-component-assembly.sh --yes
```

스크립트는 내부적으로 다음 helper Pod를 순서대로 실행한다.

```text
hami-remote-components-src-*
  Source Worker에서 checkpoint tar를 components/로 전개하고,
  .blob과 HAMi cache를 receiver storage에 복사한다.

hami-remote-components-verify-*
  Verification Node에서 receiver storage의 SHA256SUMS를 검증한다.

hami-remote-components-pack-*
  Receiver storage의 components/를 rebuilt-*.tar로 다시 조립한다.
```

성공 시 마지막에 다음과 비슷한 로그가 나온다.

```text
Remote checkpoint component assembly validated.
```

## 9. 결과 확인

Master Node에서 결과 디렉터리를 확인한다.

```bash
RESULT=$(ls -td results/*remote-checkpoint-component-assembly | head -1)

cat "$RESULT/summary.md"
cat "$RESULT/component-stage-logs.txt"
cat "$RESULT/component-verify-logs.txt"
cat "$RESULT/component-pack-logs.txt"
```

NFS Server 또는 receiver storage에서 직접 확인한다.

```bash
cd /mnt/nfs

DIR=$(find gcr_lastmonth/hami-selective-cr -maxdepth 2 -type d -name '*components' | sort | tail -1)
cd "$DIR"

ls -lh
du -sh components gcr-data hami-vgpu-cache .
head FILE_MANIFEST.tsv
cat REBUILT_TAR_SHA256SUM
tar -tf rebuilt-*.tar | head
```

성공 기준은 다음과 같다.

```text
1. components/ 디렉터리가 존재한다.
2. gcr-data/*.blob 파일이 존재한다.
3. hami-vgpu-cache/ 디렉터리가 존재한다.
4. SHA256SUMS가 존재하고 verify Pod에서 sha256sum -c SHA256SUMS가 성공했다.
5. rebuilt-*.tar 파일이 receiver storage에서 생성되었다.
6. tar -tf rebuilt-*.tar 명령으로 spec.dump, config.dump, checkpoint/*.img 등이 보인다.
```

## 10. 실제 성공 예시

실제 gpt2 checkpoint 구성요소 검증 결과 예시는 다음과 같다.

```text
components: 1.8G
gcr-data: 291M
hami-vgpu-cache: 16K
rebuilt tar: 1.8G
```

receiver storage 파일 예시:

```text
FILE_MANIFEST.tsv
REBUILT_TAR_CONTENTS.txt
REBUILT_TAR_SHA256SUM
SHA256SUMS
components/
gcr-data/
hami-vgpu-cache/
metadata.env
rebuilt-checkpoint-hami-infer-gpt2_hami-selective-cr-inference-....tar
```

`tar -tf rebuilt-*.tar | head` 예시:

```text
./
./spec.dump
./io.kubernetes.cri-o.LogPath
./config.dump
./dump.log
./bind.mounts
./stats-dump
./checkpoint/
./checkpoint/core-71.img
./checkpoint/inventory.img
```

이 결과는 receiver server에서 checkpoint tar를 다시 조립했다는 직접 증거로 사용할 수 있다.

## 11. 교수님께 설명할 때의 핵심 문장

PPT 또는 보고서에는 다음과 같이 정리할 수 있다.

```text
GCR+CRIUgpu 기반 GPU checkpoint artifact는 단일 tar 파일만으로 구성되는 것이 아니라,
CRIU/CRI-O checkpoint state와 GCR GPU memory blob, HAMi runtime cache의 조합으로 볼 수 있다.

본 검증에서는 gpt2 inference workload의 checkpoint 결과를 내부 구성요소 단위로 receiver storage에 재현하고,
SHA256 무결성 검증 후 receiver 측에서 다시 checkpoint tar를 조립하였다.

따라서 checkpoint data는 source node에서 완성된 tar 하나로만 전달될 필요가 없으며,
구성요소 단위 전송 후 remote server에서 최종 checkpoint artifact로 재구성할 수 있음을 확인하였다.
```

단, 다음 한계도 같이 말해야 한다.

```text
현재 검증은 source node에서 CRI-O가 만든 checkpoint tar를 입력으로 사용해 component 단위 재현 가능성을 확인한 것이다.
source-side tar 생성을 완전히 제거하려면 CRI-O checkpoint 경로에서 구성 파일을 생성 즉시 remote sender로 넘기는 추가 구현이 필요하다.
```

## 12. Receiver 조립 로직을 직접 구현할 때 필요한 기능

나중에 직접 receiver-side assembler를 구현한다면 최소 기능은 다음과 같다.

1. Source worker에서 넘어오는 파일 metadata를 수신한다.
2. 각 파일의 상대 경로, 크기, mode, checksum을 manifest에 기록한다.
3. CRIU/CRI-O 구성 파일은 `components/` 아래에 저장한다.
4. GCR GPU memory payload는 `gcr-data/*.blob`으로 저장한다.
5. HAMi runtime cache는 `hami-vgpu-cache/`로 저장한다.
6. 모든 파일 수신 후 checksum을 검증한다.
7. `tar -C components -cf rebuilt-checkpoint.tar .`와 같은 방식으로 checkpoint archive를 조립한다.
8. restore 시스템에 `.tar`, `.blob`, HAMi cache 위치를 넘긴다.

단순한 receiver-side pack 단계는 다음 명령과 같다.

```bash
cd /receiver/checkpoint-run

sha256sum -c SHA256SUMS
tar -C components -cf rebuilt-checkpoint.tar .
sha256sum rebuilt-checkpoint.tar > REBUILT_TAR_SHA256SUM
tar -tf rebuilt-checkpoint.tar | head
```

## 13. 문제 발생 시 확인

### helper Pod가 잘못된 node에 뜨는 경우

현재 checkpoint state가 예전 Pod를 가리키고 있을 가능성이 높다.

```bash
printf 'node=%s\n' "$(cat .state/last-checkpoint-observed-node)"
printf 'path=%s\n' "$(cat .state/last-checkpoint-path)"
printf 'container=%s\n' "$(cat .state/last-checkpoint-container)"
kubectl -n hami-selective-cr get pod hami-infer-gpt2 -o wide
kubectl -n hami-selective-cr get gpucheckpoint -o wide
```

`path`가 `checkpoint-hami-pod-a...`라면 `14-run-checkpoint-overhead-benchmark.sh`를 다시 실행하거나 `hami-infer-gpt2-checkpoint` 기준으로 state를 갱신한다.

### gcr-data blob이 없는 경우

GCR selective interception이 GPU memory segment를 잡지 못했을 수 있다.

```bash
kubectl -n hami-selective-cr logs hami-infer-gpt2 --tail=200 | grep -E 'gcr|freeze|blob|remote'
```

정상 로그 예:

```text
[gcr][engine] freeze: ... segs, ... bytes -> external blob
```

### NFS에 파일이 안 생기는 경우

NFS mount 또는 권한 문제를 확인한다.

```bash
kubectl -n hami-selective-cr describe pod -l experiment.gpu-cr/role=remote-component-stage
kubectl -n hami-selective-cr logs -l experiment.gpu-cr/role=remote-component-stage --tail=200
```

### 이전 helper Pod 정리

실패한 helper Pod가 남아 있으면 정리한다.

```bash
kubectl -n hami-selective-cr delete pod \
  -l experiment.gpu-cr/role=remote-component-stage \
  --ignore-not-found=true

kubectl -n hami-selective-cr delete pod \
  -l experiment.gpu-cr/role=remote-component-verify \
  --ignore-not-found=true

kubectl -n hami-selective-cr delete pod \
  -l experiment.gpu-cr/role=remote-component-pack \
  --ignore-not-found=true
```

## 14. 다음 개발 방향

이번 검증은 receiver-side 조립 가능성을 확인하는 단계이다. 이후 실제 시스템으로 발전시키려면 다음 구조가 필요하다.

```text
Source Worker
  ├─ GCR GPU memory remote sink
  ├─ CRIU/CRI-O component streamer
  └─ HAMi cache streamer

Receiver Server
  ├─ memory 또는 storage 기반 receiver
  ├─ manifest/checksum validator
  ├─ component directory assembler
  └─ final checkpoint artifact packer
```

궁극적으로는 다음 흐름을 목표로 할 수 있다.

```text
source에서 checkpoint 구성요소 생성
→ 생성 즉시 remote server로 stream 전송
→ receiver가 components/, gcr-data/, hami-vgpu-cache/ 구성
→ receiver가 restore 가능한 artifact 조립
```
