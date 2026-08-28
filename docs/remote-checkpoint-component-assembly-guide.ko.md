# Remote Checkpoint Component Assembly 검증 가이드

이 문서는 GCR+CRIUgpu 기반 checkpoint 결과를 `.tar` 파일 하나로 전송하지 않고, checkpoint 내부 구성요소를 파일 단위로 receiver storage에 전송할 수 있는지 검증하기 위한 절차이다.

## 검증 목표

검증하고 싶은 내용은 세 단계로 나눈다.

1. Source Worker에서 checkpoint archive를 통째로 복사하지 않고 내부 구성 파일을 receiver storage에 파일 단위로 전송할 수 있는가?
2. Receiver storage에서 checkpoint directory 구조와 파일 무결성을 그대로 재현할 수 있는가?
3. Receiver storage에서 재현된 구성요소를 다시 `.tar` checkpoint artifact로 조립할 수 있는가?

이 검증은 “전송 artifact가 반드시 `.tar`일 필요는 없다”는 것을 확인한다. 다만 현재 CRI-O checkpoint 구현은 source node에서 checkpoint tar를 먼저 만들기 때문에, 이 스크립트는 이미 생성된 tar를 source worker에서 내부 파일로 풀어 receiver storage에 전개한다. 즉, source-side tar 생성을 완전히 제거하는 검증은 아니다.

## 현재 검증으로 말할 수 있는 것

성공하면 다음을 주장할 수 있다.

```text
Checkpoint artifact는 논리적으로 여러 구성 파일의 집합이므로,
source에서 완성된 tar 파일 하나를 전송하지 않아도 receiver storage에 동일한 파일 구조를 재현할 수 있다.
또한 receiver storage에서 재현된 구성요소를 다시 tar로 조립할 수 있다.
```

이미 별도로 검증한 remote memory sink 결과와 연결하면 다음과 같이 정리할 수 있다.

```text
GPU memory payload는 checkpoint 중 remote memory receiver로 전송 가능하다.
CRIU/CRI-O metadata와 rootfs/config 계열 파일은 파일 단위 전송으로 receiver storage에 재현 가능하다.
따라서 remote host가 checkpoint 구성요소를 수신하고 최종 artifact를 조립하는 구조는 구현 가능한 방향이다.
```

## 전제 조건

Master Node에서 다음 상태가 준비되어 있어야 한다.

- `config/experiment.env`가 존재해야 한다.
- `NFS_SERVER=10.178.0.14`
- `NFS_EXPORT_PATH=/mnt/nfs`
- `NFS_ARTIFACT_SUBDIR=gcr_lastmonth/hami-selective-cr`
- GPUCheckpoint가 최소 1회 성공해서 `.state/last-checkpoint-path`가 있어야 한다.
- Source Worker와 검증 Worker가 NFS export를 Pod volume으로 mount할 수 있어야 한다.

확인 명령어:

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore

cat .state/last-checkpoint-path
cat .state/last-checkpoint-source-pod-uid
cat .state/last-checkpoint-observed-node
grep -E '^(NFS_SERVER|NFS_EXPORT_PATH|NFS_ARTIFACT_SUBDIR|TARGET_NODE)=' config/experiment.env
```

## 실행

기본 실행:

```bash
cd ~/HAMi-Selective-GPU-Checkpoint-Restore

bash ./scripts/18-validate-remote-checkpoint-component-assembly.sh --yes
```

특정 검증 Node를 지정하려면 `config/experiment.env`에서 `TARGET_NODE`를 설정한다.

```bash
sed -i 's/^TARGET_NODE=.*/TARGET_NODE=jsj-worker-2/' config/experiment.env

bash ./scripts/18-validate-remote-checkpoint-component-assembly.sh --yes
```

## 스크립트가 하는 일

스크립트는 다음을 수행한다.

1. `.state/last-checkpoint-path`에서 최신 checkpoint tar 경로를 읽는다.
2. Source Worker에 helper Pod를 띄운다.
3. Source Worker의 checkpoint tar를 NFS receiver storage 안의 `components/` 디렉터리로 전개한다.
4. Source Worker의 GCR `.blob` 파일을 `gcr-data/` 디렉터리에 복사한다.
5. Source Worker의 HAMi vGPU cache가 있으면 `hami-vgpu-cache/`로 복사한다.
6. 모든 구성 파일의 `SHA256SUMS`와 `FILE_MANIFEST.tsv`를 생성한다.
7. 검증 Node에 helper Pod를 띄워 receiver storage의 checksum을 검증한다.
8. receiver storage 안의 `components/` 디렉터리를 다시 `.tar`로 조립한다.
9. 결과 경로를 `.state/remote-component-*` 파일에 기록한다.

## 결과 확인

실행이 성공하면 결과 디렉터리의 `summary.md`를 확인한다.

```bash
RESULT=$(ls -td results/*remote-checkpoint-component-assembly | head -1)
cat "$RESULT/summary.md"
cat "$RESULT/component-stage-logs.txt"
cat "$RESULT/component-verify-logs.txt"
cat "$RESULT/component-pack-logs.txt"
```

성공 기준은 다음과 같다.

```text
component-stage: component directory 생성 및 SHA256SUMS 생성 성공
component-verify: sha256sum -c SHA256SUMS 성공
component-pack: rebuilt-*.tar 생성 성공
```

NFS server에서 직접 확인하려면 다음을 실행한다.

```bash
cd /mnt/nfs
find gcr_lastmonth/hami-selective-cr -maxdepth 2 -type d -name '*components' | sort | tail

DIR=$(find gcr_lastmonth/hami-selective-cr -maxdepth 2 -type d -name '*components' | sort | tail -1)
cd "$DIR"

ls -lh
head FILE_MANIFEST.tsv
cat REBUILT_TAR_SHA256SUM
tar -tf rebuilt-*.tar | head
```

## 해석

성공했다면 다음과 같이 해석한다.

```text
1차 검증 성공:
checkpoint tar 자체를 전송하지 않고 내부 구성 파일을 receiver storage에 재현했다.

2차 검증 성공:
receiver storage에서 파일 목록과 SHA256 checksum이 유지되었다.

3차 검증 성공:
receiver storage에서 구성 파일을 다시 checkpoint tar 형태로 조립했다.
```

## 한계

이 검증은 source node에서 이미 만들어진 checkpoint tar를 입력으로 사용한다. 따라서 다음을 의미하지는 않는다.

```text
CRI-O가 source node에서 tar를 전혀 만들지 않았다.
```

source-side tar 생성 자체를 제거하려면 CRI-O checkpoint 경로에서 CRIU dump output directory를 remote sender로 직접 넘기거나, CRIU page-server와 GCR remote sink를 하나의 receiver protocol로 묶는 추가 구현이 필요하다.

## 다음 단계

이 검증이 성공하면 다음 개발 방향을 잡을 수 있다.

- GCR GPU blob: checkpoint 중 remote memory sink로 전송
- CRIU/CRI-O 구성 파일: 파일 단위 streamer로 receiver storage에 전송
- Receiver: manifest/checksum 검증 후 최종 checkpoint artifact 조립
- Restore: receiver가 만든 artifact를 restore input으로 사용
