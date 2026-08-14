# Troubleshooting

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

## Checkpoint CRD Is Unknown

Inspect the base repository and installed CRDs:

```bash
kubectl api-resources | grep -Ei 'checkpoint|restore|gpu'
kubectl get crd | grep -Ei 'checkpoint|restore|gpu'
```

Then update `manifests/checkpoint-resources.yaml`.

If the full runner stops at `08-checkpoint-pod-a` with:

```text
no matches for kind "WorkloadCheckpoint"
no matches for kind "WorkloadRestore"
```

the CUDA workloads and HAMi scheduling already passed, but the base GPU
Checkpoint/Restore CRDs are not installed in the cluster or the manifest uses
the wrong `apiVersion`.

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

Install those CRDs/operator first. If the real Kind names or API groups differ,
edit `manifests/checkpoint-resources.yaml` to match the installed CRDs and then
resume:

```bash
./scripts/00-run-full-experiment.sh --yes --from 08-checkpoint-pod-a
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
