# 장애 대응

## HAMi Pods Are Not Running

Run:

```bash
kubectl -n kube-system get pods -o wide
kubectl -n kube-system describe pod -l app.kubernetes.io/name=hami
```

Confirm GPU nodes are labeled:

```bash
kubectl get nodes --show-labels | grep 'gpu=on'
```

## Pod Scheduling Fails

Check HAMi resource names in `config/experiment.env`. Current defaults are:

- `nvidia.com/gpu`
- `nvidia.com/gpumem`
- `nvidia.com/gpucores`

Also check node annotations and scheduler logs.

If `kubectl describe pod` shows events from `default-scheduler` with messages like:

```text
Insufficient nvidia.com/gpucores
Insufficient nvidia.com/gpumem
```

then the Pod did not go through the HAMi scheduler path. The experiment Pods
must use:

```yaml
spec:
  schedulerName: hami-scheduler
```

Verify:

```bash
kubectl -n hami-selective-cr get pod hami-pod-a hami-pod-b \
  -o custom-columns=NAME:.metadata.name,SCHEDULER:.spec.schedulerName,PHASE:.status.phase,NODE:.spec.nodeName
kubectl -n kube-system get pods | grep -Ei 'hami|vgpu'
kubectl get nodes --show-labels | grep 'gpu=on'
```

After updating the manifest, recreate the experiment Pods:

```bash
kubectl -n hami-selective-cr delete pod hami-pod-a hami-pod-b --ignore-not-found
./scripts/05-deploy-test-workloads.sh --yes
```

## GPUCheckpoint CRD가 없다고 나올 때

Inspect the base repository and installed CRDs:

```bash
kubectl api-resources | grep -Ei 'checkpoint|restore|gpu'
kubectl get crd | grep -Ei 'checkpoint|restore|gpu'
```

정상이라면 `gpucheckpoints.gpu-cr.io`가 보여야 합니다.

전체 실행이 `10-checkpoint-pod-a`에서 아래처럼 멈추면:

```text
GPUCheckpoint CRD is not installed
```

HAMi와 CUDA workload 배포는 통과했지만, 체크포인트 시스템의 CRD/Node Agent가 아직 설치되지 않은 것입니다.

Check the cluster:

```bash
kubectl get crd | grep -Ei 'checkpoint|restore|gpu|workload'
kubectl api-resources | grep -Ei 'checkpoint|restore|gpu|workload'
```

Check the sibling base repository for CRD manifests:

```bash
find ../K8s-Native-Fast-GPU-Checkpoint-Restore-System \
  -type f \( -name '*.yaml' -o -name '*.yml' \) \
  -exec grep -H 'kind: CustomResourceDefinition' {} \;
```

해결:

```bash
./scripts/04-install-gpu-cr-checkpoint-system.sh --yes
./scripts/00-run-full-experiment.sh --yes --from 10-checkpoint-pod-a
```

## Restore Pod가 Ready가 안 될 때

`11-restore-pod-a`에서 실패하면 대부분 Kubernetes CRD 문제가 아니라 Worker Node runtime 문제입니다.

확인:

```bash
kubectl -n hami-selective-cr describe pod hami-pod-a-restored
kubectl -n hami-selective-cr get events --sort-by=.lastTimestamp
```

대상 Worker Node에서 확인:

```bash
systemctl is-active crio
systemctl is-active gpu-cr-restore-agent.service
journalctl -u crio -n 100
journalctl -u gpu-cr-restore-agent.service -n 100
ls -lh /var/lib/gcr-checkpoint
ls -lh /var/lib/gcr-data
```

필요하면 Worker Node에서:

```bash
cd ../K8s-Native-GPU-Restore-CRI-O
sudo bash hack/build-crio.sh
sudo bash scripts/install-node.sh
```

## Checkpoint는 Completed인데 `.blob`이 없을 때

`gpu-cr-node-agent` 로그에 아래처럼 나오면 GCR selective data path가 GPU allocation을 잡지 못한 것입니다.

```text
GCR interception on but no data blob at /var/lib/gcr-data/<podUID>/data.blob
```

확인:

```bash
kubectl -n hami-selective-cr logs hami-pod-a --tail=200 | grep -Ei 'gcr|vmm|cudaMalloc|libcudart'
kubectl -n hami-selective-cr describe pod hami-pod-a | grep -E 'LD_PRELOAD|GCR_|/opt/gpu-cr|/var/lib/gcr' -A2 -B2
```

Pod A 로그에 `libcudart.so`가 보여야 `LD_PRELOAD`가 CUDA runtime API를 가로챌 수 있습니다. `nvcc`가 static cudart로 빌드하면 interceptor는 checkpoint signal은 받지만 `cudaMalloc`을 소유하지 못해서 `.blob`이 생기지 않을 수 있습니다.

이 저장소의 기본 Pod A manifest는 `nvcc -cudart shared`로 빌드합니다. 최신 코드를 받은 뒤 Pod A/B를 재생성하고 다시 checkpoint 하세요.

```bash
git pull origin main
kubectl -n hami-selective-cr delete pod hami-pod-a hami-pod-b --ignore-not-found
./scripts/05-deploy-test-workloads.sh --yes
./scripts/08-run-gcr-criu-selective-test.sh --yes
```

## Pod B Stops During Checkpoint

This is a feasibility failure unless logs show an unrelated node or runtime issue. Collect:

```bash
kubectl -n hami-selective-cr describe pod hami-pod-b
kubectl -n hami-selective-cr logs hami-pod-b --previous
kubectl -n hami-selective-cr get events --sort-by=.lastTimestamp
```

## Restore Fails After GPU UUID Change

Confirm the base C/R implementation's GPU UUID remap mechanism. Do not hardcode UUIDs in manifests or scripts.

## Restore Fails With Missing HAMi Bind Mounts

If CRI-O logs show a message like this:

```text
missing bind mounts: /tmp/vgpulock,/etc/ld.so.preload,/usr/local/vgpu,/usr/local/vgpu/libvgpu.so
```

then the checkpoint and `.blob` may already be staged correctly, but CRIU cannot
recreate the bind mounts that HAMi injected into the original Pod. Confirm the
actual host sources on the checkpointed Worker Node:

```bash
CKPT=/var/lib/gcr-checkpoint/checkpoint-hami-pod-a_hami-selective-cr-selective-target-1786711554.tar
WORK=$(mktemp -d)
sudo tar -xf "$CKPT" -C "$WORK" spec.dump

sudo python3 - "$WORK/spec.dump" <<'PY'
import json, os, sys
spec = json.load(open(sys.argv[1]))
for m in spec.get("mounts", []):
    dst = m.get("destination", "")
    src = m.get("source", "")
    if any(x in dst for x in ["vgpu", "ld.so.preload", "vgpulock"]):
        print(f"{src} -> {dst} exists={os.path.exists(src)}")
PY
```

The restore script now provides these HAMi mounts explicitly. If your HAMi
version does not use `/usr/local/vgpu/libvgpu.so.v2.9.0`, set the correct path in
`config/experiment.env`:

```bash
RESTORE_HAMI_LIBVGPU_SOURCE=/usr/local/vgpu/libvgpu.so.<your-version>
```
