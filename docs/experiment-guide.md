# Experiment Guide

## Goal

Verify whether Pod A can be selectively checkpointed and restored while Pod B continues running on the same physical GPU through HAMi sharing.

## Scope

Included:

- Two independent single-process CUDA workloads
- HAMi GPU sharing with memory and core limits
- Same-node and same-GPU checkpoint/restore first
- Pod recreation restore
- Same-worker restore on the source GPU worker

Excluded:

- MIG
- MPS
- NCCL
- CUDA IPC
- UVM
- Inter-process communication between Pod A and Pod B
- Dynamic repacking or bin-packing

## Procedure

1. Copy `config/experiment.env.example` to `config/experiment.env`.
2. Fill image names, checkpoint paths, and any CRIU/GCR paths confirmed from the base repository.
3. Run `scripts/00-preflight.sh`.
4. Run `scripts/01-backup-current-environment.sh`.
5. Install HAMi with `scripts/02-install-hami.sh --yes`.
6. Verify HAMi with `scripts/03-verify-hami.sh`.
7. Optionally run `scripts/04-build-test-images.sh` only if custom workload images are configured.
8. Deploy Pod A and Pod B with `scripts/05-deploy-test-workloads.sh --yes`.
9. Capture baseline with `scripts/06-run-baseline-test.sh`.
10. Run selective checkpoint with `scripts/08-run-gcr-criu-selective-test.sh --yes`.
11. Check that Pod B heartbeat logs continue through the checkpoint window.
12. Run restore-in-new-pod with `scripts/09-run-pod-recreation-test.sh --yes`.
13. Collect results with `scripts/11-collect-results.sh`.

Cross-node restore is intentionally outside the default run. Use
`scripts/10-run-cross-node-restore-test.sh --yes` only for a later extension.

## Notes

`manifests/checkpoint-resources.yaml` intentionally uses placeholder CRD group names until the base C/R repository is inspected. Replace `apiVersion`, `kind`, and fields with the exact installed CRDs before live execution.

The default workload path does not require user-selected images. The deploy script creates ConfigMaps from the CUDA source under `workloads/` and compiles those sources inside `nvidia/cuda:12.4.1-devel-ubuntu22.04` when each Pod starts.
