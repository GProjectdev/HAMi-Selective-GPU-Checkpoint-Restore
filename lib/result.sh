#!/usr/bin/env bash
set -Eeuo pipefail

capture() {
  local name="$1"
  shift
  log "Capturing ${name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf 'DRY_RUN: %s\n' "$*" > "${RESULT_DIR}/${name}.txt"
  else
    "$@" > "${RESULT_DIR}/${name}.txt" 2>&1 || true
  fi
}

append_summary() {
  local file="${RESULT_DIR}/summary.md"
  printf '%s\n' "$*" >> "${file}"
}

