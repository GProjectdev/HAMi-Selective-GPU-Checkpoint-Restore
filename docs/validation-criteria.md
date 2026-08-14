# 검증 기준

## 성공 기준

- Pod A와 Pod B가 같은 GPU Worker Node에 배치된다.
- Pod A와 Pod B가 사용자가 별도 이미지를 만들지 않아도 repo 제공 CUDA workload를 실행한다.
- Pod A가 checkpoint 전 CUDA heartbeat 로그를 출력한다.
- Pod B가 Pod A checkpoint/restore 전, 중, 후에 계속 heartbeat 로그를 출력한다.
- `GPUCheckpoint`가 `Completed` 상태가 된다.
- `GPUCheckpoint.status.lastCheckpointPath`에 checkpoint tar 경로가 기록된다.
- `GPUCheckpoint.status.podUID`에 원본 Pod UID가 기록된다.
- checkpoint tar와 blob이 `/var/lib/gcr-checkpoint` 기준 경로에 존재한다.
- `hami-pod-a-restored`가 같은 Worker Node에서 Ready가 된다.
- Pod B가 restart되지 않는다.

## 실패 기준

- Pod B가 Pod A checkpoint 중 restart 또는 exit된다.
- Pod B의 CUDA heartbeat가 멈춘다.
- HAMi scheduler가 Pod A와 Pod B를 서로 다른 물리 GPU/Worker Node에 배치한다.
- Pod A가 아닌 Pod B 상태까지 checkpoint 대상에 포함된다.
- Restore가 node name, IP, GPU UUID 하드코딩 없이는 진행되지 않는다.
- `hami-pod-a-restored`가 patched CRI-O/restore hook 부재로 생성되지 않는다.

## 수집해야 할 증거

- `kubectl -n hami-selective-cr get pods -o wide`
- Pod A, Pod B, restored Pod 로그
- `GPUCheckpoint` YAML
- `kubectl -n hami-selective-cr get events --sort-by=.lastTimestamp`
- HAMi scheduler/device-plugin 로그
- `gpu-cr-node-agent` Pod 상태
- `/var/lib/gcr-checkpoint` tar/blob 크기
- Worker Node의 `crio`, `gpu-cr-restore-agent.service` 상태
