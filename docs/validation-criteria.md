# Validation Criteria

## Success Criteria

- Pod A and Pod B are scheduled on the same source worker and consume HAMi GPU resources.
- Pod A and Pod B run the repository-provided CUDA workloads without requiring user-provided workload images.
- Pod A produces CUDA heartbeat logs before checkpoint.
- Pod B produces CUDA heartbeat logs before, during, and after Pod A checkpoint.
- Pod A checkpoint object reaches the successful state defined by the base C/R system.
- Pod A GPU data and control state are stored in the configured checkpoint path.
- Pod A restore succeeds in the same Pod or a recreated Pod.
- Pod B does not restart, lose CUDA context, or stop producing heartbeats during Pod A checkpoint/restore.
- Pod A restore succeeds on the same Worker Node selected as `SOURCE_NODE`.

## Failure Criteria

- Pod B restarts or exits during Pod A checkpoint.
- GPU memory used by Pod B is reclaimed or corrupted.
- HAMi scheduler places Pod A and Pod B on different physical GPUs during the same-GPU test.
- Checkpoint captures non-target Pod state.
- Restore requires manual node, IP, or GPU UUID hardcoding.

## Evidence To Collect

- `kubectl get pods -o wide`
- Pod A and Pod B logs before and after checkpoint
- `nvidia-smi` output from both Pods
- WorkloadCheckpoint and WorkloadRestore status
- HAMi scheduler/device-plugin logs
- Node annotations and allocatable resources
- Checkpoint directory listing and sizes
