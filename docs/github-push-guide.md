# GitHub Push Guide

## Remote

Expected remote:

```bash
git remote add origin https://github.com/GProjectdev/HAMi-Selective-GPU-Checkpoint-Restore.git
```

## Branch

Expected branch:

```bash
experiment/hami-selective-cr
```

## Scripted Push

Copy the example auth file and fill only non-sensitive public values unless your environment requires a token:

```bash
cp config/github-auth.env.example config/github-auth.env
./scripts/98-commit-and-push.sh --yes
```

The script does not print token values.

