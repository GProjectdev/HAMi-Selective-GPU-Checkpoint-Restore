#!/usr/bin/env bash
set -Eeuo pipefail

PORT=19090
OUTPUT_DIR=""
KEEP_STREAM_ARCHIVE="false"

usage() {
  cat <<'EOF'
Usage:
  scripts/16-start-remote-memory-receiver.sh [options]

Options:
  --port <port>                  TCP listen port. Default: 19090
  --output-dir <dir>             Directory for received files. Default: /dev/shm/gcr-remote-memory/<timestamp>
  --keep-stream-archive          Keep the intermediate incoming-stream.tar file.
  -h, --help                     Show this help.

Purpose:
  Receive a GCR checkpoint artifact stream into a RAM-backed directory such as
  /dev/shm. The sender should be scripts/17-send-latest-checkpoint-to-remote-memory.sh.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) shift; PORT="${1:?missing port}" ;;
    --output-dir) shift; OUTPUT_DIR="${1:?missing output dir}" ;;
    --keep-stream-archive) KEEP_STREAM_ARCHIVE="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

command -v nc >/dev/null 2>&1 || { echo "ERROR: nc is required." >&2; exit 10; }
command -v tar >/dev/null 2>&1 || { echo "ERROR: tar is required." >&2; exit 10; }
command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum is required." >&2; exit 10; }

if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="/dev/shm/gcr-remote-memory/$(date -u '+%Y%m%dT%H%M%SZ')"
fi

mkdir -p "${OUTPUT_DIR}"
LOG_FILE="${OUTPUT_DIR}/receiver.log"
STREAM_ARCHIVE="${OUTPUT_DIR}/incoming-stream.tar"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "${LOG_FILE}" >&2
}

listen_nc() {
  if nc -h 2>&1 | grep -Eq -- '(^|[[:space:]])-p([,[:space:]]|$)'; then
    nc -l -p "${PORT}"
  else
    nc -l "${PORT}"
  fi
}

log "Remote memory receiver starting"
log "port=${PORT}"
log "output-dir=${OUTPUT_DIR}"
df -h "${OUTPUT_DIR}" | tee -a "${LOG_FILE}" >&2 || true

start_ns="$(date +%s%N)"
listen_nc > "${STREAM_ARCHIVE}"
end_ns="$(date +%s%N)"

bytes="$(wc -c < "${STREAM_ARCHIVE}" | tr -d ' ')"
duration_s="$(awk -v s="${start_ns}" -v e="${end_ns}" 'BEGIN { printf "%.6f", (e - s) / 1000000000 }')"
throughput_mib_s="$(awk -v b="${bytes}" -v d="${duration_s}" 'BEGIN { if (d > 0) printf "%.3f", b / 1048576 / d; else printf "0.000" }')"

log "stream received: bytes=${bytes} duration_s=${duration_s} throughput_mib_s=${throughput_mib_s}"
tar -tf "${STREAM_ARCHIVE}" > "${OUTPUT_DIR}/archive-list.txt"
tar -xf "${STREAM_ARCHIVE}" -C "${OUTPUT_DIR}"

find "${OUTPUT_DIR}" -maxdepth 1 -type f \( -name '*.tar' -o -name '*.blob' \) -print0 |
  xargs -0 sha256sum > "${OUTPUT_DIR}/SHA256SUMS"

{
  printf 'received_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'port=%s\n' "${PORT}"
  printf 'output_dir=%s\n' "${OUTPUT_DIR}"
  printf 'stream_bytes=%s\n' "${bytes}"
  printf 'duration_s=%s\n' "${duration_s}"
  printf 'throughput_mib_s=%s\n' "${throughput_mib_s}"
} > "${OUTPUT_DIR}/manifest.env"

if [[ "${KEEP_STREAM_ARCHIVE}" != "true" ]]; then
  rm -f "${STREAM_ARCHIVE}"
fi

log "received files:"
find "${OUTPUT_DIR}" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort | tee -a "${LOG_FILE}" >&2
log "done"
