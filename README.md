# HAMi-Aware Selective Checkpoint/Restore for Shared GPUs

This repository contains a feasibility experiment for selective GPU checkpoint and restore in a HAMi shared-GPU Kubernetes environment.

The target scenario is two independent CUDA Pods sharing one physical NVIDIA A100 through HAMi. Pod A is checkpointed and restored while Pod B keeps running. This experiment does not implement dynamic repacking or bin-packing.

## Local Path

Created at:

`C:\Users\JeongSeungJun\Desktop\졸업준비\HAMi-Selective-GPU-Checkpoint-Restore`

The requested reference repository is expected at:

`../K8s-Native-Fast-GPU-Checkpoint-Restore-System`

If the reference repository is missing, clone it next to this repository:

```bash
git clone https://github.com/GProjectdev/K8s-Native-Fast-GPU-Checkpoint-Restore-System.git
```

If this repository should be cloned from GitHub instead of using this generated local workspace:

```bash
git clone https://github.com/GProjectdev/HAMi-Selective-GPU-Checkpoint-Restore.git
```

## Quick Start

```bash
cp config/experiment.env.example config/experiment.env
$EDITOR config/experiment.env

make preflight
make backup
make install-hami
make verify-hami
make build-images
make deploy
make baseline
make selective-cr
make collect
```

All scripts support `--dry-run`. Scripts that change cluster resources require `--yes`.

## Safety Boundaries

- Does not modify Cilium, CoreDNS, or the control plane.
- Does not run `kubeadm reset`.
- Does not stop, delete, or recreate VMs.
- Does not hardcode node names, IP addresses, or GPU UUIDs.
- Treats `../K8s-Native-Fast-GPU-Checkpoint-Restore-System` as read-only.

## External HAMi References

HAMi current documentation identifies the default NVIDIA resource names as `nvidia.com/gpu`, `nvidia.com/gpumem`, and `nvidia.com/gpucores`, and documents Helm installation through `hami-charts` after labeling GPU nodes with `gpu=on`.

