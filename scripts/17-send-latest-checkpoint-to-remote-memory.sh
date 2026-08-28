#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE_HOST=""
PORT=19090
CHECKPOINT_PATH=""
RESULT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/17-send-latest-checkpoint-to-remote-memory.sh --remote-host <host> [options]

Options:
  --remote-host <host>           Receiver host/IP. Required.
  --port <port>                  Receiver TCP port. Default: 19090
  --checkpoint-path <path>       Checkpoint tar path. Default: latest /var/lib/gcr-checkpoint/*.tar
  --result-dir <dir>             Local sender result directory.
  -h, --help                     Show this help.

Purpose:
  Send the latest GCR checkpoint tar and matching external GPU blob as one tar
  stream to scripts/16-start-remote-memory-receiver.sh on another host.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host) shift; REMOTE_HOST="${1:?missing remote host}" ;;
    --port) shift; PORT="${1:?missing port}" ;;
    --checkpoint-path) shift; CHECKPOINT_PATH="${1:?missing checkpoint path}" ;;
    --result-dir) shift; RESULT_DIR="${1:?missing result dir}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -n "${REMOTE_HOST}" ]] || { echo "ERROR: --remote-host is required." >&2; usage >&2; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "ERROR: nc is required." >&2; exit 10; }
command -v tar >/dev/null 2>&1 || { echo "ERROR: tar is required." >&2; exit 10; }
command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum is required." >&2; exit 10; }

if [[ -z "${CHECKPOINT_PATH}" ]]; then
  CHECKPOINT_PATH="$(ls -t /var/lib/gcr-checkpoint/*.tar 2>/dev/null | head -1 || true)"
fi
[[ -n "${CHECKPOINT_PATH}" ]] || { echo "ERROR: no checkpoint tar found. Use --checkpoint-path." >&2; exit 11; }
[[ -f "${CHECKPOINT_PATH}" ]] || { echo "ERROR: checkpoint tar not found: ${CHECKPOINT_PATH}" >&2; exit 11; }

BLOB_PATH="${CHECKPOINT_PATH%.tar}.blob"
[[ -f "${BLOB_PATH}" ]] || { echo "ERROR: matching blob not found: ${BLOB_PATH}" >&2; exit 12; }

if [[ -z "${RESULT_DIR}" ]]; then
  RESULT_DIR="/tmp/gcr-remote-memory-send-$(date -u '+%Y%m%dT%H%M%SZ')"
fi
mkdir -p "${RESULT_DIR}"
LOG_FILE="${RESULT_DIR}/sender.log"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "${LOG_FILE}" >&2
}

CHECKPOINT_DIR="$(cd "$(dirname "${CHECKPOINT_PATH}")" && pwd)"
TAR_NAME="$(basename "${CHECKPOINT_PATH}")"
BLOB_NAME="$(basename "${BLOB_PATH}")"
TOTAL_BYTES="$(awk -v a="$(wc -c < "${CHECKPOINT_PATH}")" -v b="$(wc -c < "${BLOB_PATH}")" 'BEGIN { print a + b }')"

sha256sum "${CHECKPOINT_PATH}" "${BLOB_PATH}" > "${RESULT_DIR}/sender-SHA256SUMS"

log "Sending checkpoint artifacts to ${REMOTE_HOST}:${PORT}"
log "checkpoint=${CHECKPOINT_PATH}"
log "blob=${BLOB_PATH}"
log "payload_bytes=${TOTAL_BYTES}"

start_ns="$(date +%s%N)"
tar -C "${CHECKPOINT_DIR}" -cf - "${TAR_NAME}" "${BLOB_NAME}" | nc "${REMOTE_HOST}" "${PORT}"
end_ns="$(date +%s%N)"

duration_s="$(awk -v s="${start_ns}" -v e="${end_ns}" 'BEGIN { printf "%.6f", (e - s) / 1000000000 }')"
throughput_mib_s="$(awk -v b="${TOTAL_BYTES}" -v d="${duration_s}" 'BEGIN { if (d > 0) printf "%.3f", b / 1048576 / d; else printf "0.000" }')"

{
  printf 'sent_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'remote_host=%s\n' "${REMOTE_HOST}"
  printf 'port=%s\n' "${PORT}"
  printf 'checkpoint_path=%s\n' "${CHECKPOINT_PATH}"
  printf 'blob_path=%s\n' "${BLOB_PATH}"
  printf 'payload_bytes=%s\n' "${TOTAL_BYTES}"
  printf 'duration_s=%s\n' "${duration_s}"
  printf 'throughput_mib_s=%s\n' "${throughput_mib_s}"
} > "${RESULT_DIR}/manifest.env"

log "send complete: duration_s=${duration_s} throughput_mib_s=${throughput_mib_s}"
log "sender result dir: ${RESULT_DIR}"
