#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "${REPO_ROOT}/lib/github.sh"

parse_common_args "$@"
load_env
init_result_dir git-push
require_cmd git
load_github_env
ensure_remote

branch="${GITHUB_BRANCH:-experiment/hami-selective-cr}"
run_cmd git -C "${REPO_ROOT}" checkout -B "${branch}"
run_cmd git -C "${REPO_ROOT}" add README.md LICENSE .gitignore Makefile config scripts manifests workloads lib docs results backups .state
run_cmd git -C "${REPO_ROOT}" commit -m "Document HAMi selective GPU checkpoint feasibility experiment

Constraint: Existing fast GPU C/R repository is treated as read-only reference.
Confidence: high
Scope-risk: narrow
Directive: Keep cluster-mutating scripts gated by --yes and environment variables.
Tested: bash -n over shell scripts; manifest YAML parsed locally.
Not-tested: live Kubernetes/HAMi/GPU execution is environment-gated."
confirm_destructive "Pushing ${branch} to origin"
run_cmd git -C "${REPO_ROOT}" push -u origin "${branch}"

