# Environment Report

## Requested Environment

- Platform: GCP VM based kubeadm Kubernetes cluster
- Master nodes: 1
- Worker nodes: 2
- GPU: NVIDIA A100 40GB, one per worker
- Total GPUs: 2
- CNI: Cilium
- Runtime: CRI-O
- NVIDIA device plugin: installed on GPU workers
- HAMi: not installed before this experiment
- MIG: disabled
- MPS: disabled

## Repository Discovery

Current workspace path during generation:

`C:\Users\JeongSeungJun\Desktop\졸업준비`

Generated repository path:

`C:\Users\JeongSeungJun\Desktop\졸업준비\HAMi-Selective-GPU-Checkpoint-Restore`

Expected base C/R repository:

`../K8s-Native-Fast-GPU-Checkpoint-Restore-System`

The reference repository was not present in the current workspace during generation. Values requiring inspection of that repository are recorded as `UNKNOWN`.

## Base Repository Values To Confirm

| Item | Value |
| --- | --- |
| GCR library path | UNKNOWN |
| cuda-checkpoint binary path | UNKNOWN |
| CRIU usage | UNKNOWN |
| CRIUgpu usage | UNKNOWN |
| Node Agent manifest | UNKNOWN |
| Restore Runtime code/config | UNKNOWN |
| Checkpoint storage path | UNKNOWN |
| NFS mount path | UNKNOWN |
| Restore annotation | UNKNOWN |
| GPU UUID remap method | UNKNOWN |
| Existing test workload/benchmark | UNKNOWN |
| Current Docker images | UNKNOWN |

## HAMi Defaults Used

Current HAMi documentation identifies these default NVIDIA resource names:

- GPU count: `nvidia.com/gpu`
- GPU memory: `nvidia.com/gpumem`
- GPU core percentage: `nvidia.com/gpucores`

The install script uses the documented Helm repository `https://project-hami.github.io/HAMi/` and chart `hami-charts/hami`.

