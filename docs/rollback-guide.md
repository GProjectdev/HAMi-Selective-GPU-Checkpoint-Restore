# Rollback Guide

Rollback is intentionally scoped to experiment resources.

## Delete Test Resources

```bash
./scripts/12-clean-test-resources.sh --yes
```

## Remove HAMi Installed By This Experiment

```bash
./scripts/99-rollback-to-original-environment.sh --yes
```

This removes the experiment namespace and uninstalls the `hami` Helm release if it exists.

## Not Performed

Rollback scripts do not:

- Modify Cilium
- Modify CoreDNS
- Modify control plane components
- Run `kubeadm reset`
- Stop, delete, or recreate VMs
- Delete checkpoint archives unless you explicitly remove them

