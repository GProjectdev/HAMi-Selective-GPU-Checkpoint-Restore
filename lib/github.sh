#!/usr/bin/env bash
set -Eeuo pipefail

load_github_env() {
  local file="${REPO_ROOT}/config/github-auth.env"
  [[ -f "${file}" ]] || die "Missing config/github-auth.env. Copy config/github-auth.env.example first."
  set -a
  # shellcheck disable=SC1090
  source "${file}"
  set +a
}

ensure_remote() {
  local url="${GITHUB_REMOTE_URL:-https://github.com/GProjectdev/HAMi-Selective-GPU-Checkpoint-Restore.git}"
  if git -C "${REPO_ROOT}" remote get-url origin >/dev/null 2>&1; then
    git -C "${REPO_ROOT}" remote set-url origin "${url}"
  else
    git -C "${REPO_ROOT}" remote add origin "${url}"
  fi
}

