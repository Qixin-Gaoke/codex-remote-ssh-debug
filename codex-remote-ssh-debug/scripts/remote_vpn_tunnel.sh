#!/bin/zsh
set -u

if (( $# < 1 )); then
  echo "usage: $0 <ssh-host-alias> [remote-proxy-port] [local-proxy-port]" >&2
  exit 2
fi

REMOTE_HOST="$1"
REMOTE_PROXY_PORT="${2:-27897}"
LOCAL_PROXY_HOST="127.0.0.1"
LOCAL_PROXY_PORT="${3:-7897}"
REMOTE_FORWARD="127.0.0.1:${REMOTE_PROXY_PORT}:${LOCAL_PROXY_HOST}:${LOCAL_PROXY_PORT}"
INITIAL_BACKOFF_SECONDS=30
BACKOFF_SECONDS="${INITIAL_BACKOFF_SECONDS}"
MAX_BACKOFF_SECONDS=300
STABLE_RESET_SECONDS=120

log() {
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${REMOTE_HOST}" "$*"
}

while true; do
  if ! /usr/bin/nc -z "${LOCAL_PROXY_HOST}" "${LOCAL_PROXY_PORT}" >/dev/null 2>&1; then
    log "local proxy ${LOCAL_PROXY_HOST}:${LOCAL_PROXY_PORT} is unavailable; retrying in 30s"
    sleep 30
    continue
  fi

  started_at="$(date +%s)"
  log "starting reverse tunnel ${REMOTE_HOST}:127.0.0.1:${REMOTE_PROXY_PORT} -> ${LOCAL_PROXY_HOST}:${LOCAL_PROXY_PORT}"
  /usr/bin/ssh \
    -N \
    -T \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o TCPKeepAlive=yes \
    -R "${REMOTE_FORWARD}" \
    "${REMOTE_HOST}"

  rc=$?
  ended_at="$(date +%s)"
  runtime_seconds=$(( ended_at - started_at ))
  log "ssh tunnel exited with code ${rc}; retrying in ${BACKOFF_SECONDS}s"
  sleep "${BACKOFF_SECONDS}"

  if (( runtime_seconds >= STABLE_RESET_SECONDS )); then
    BACKOFF_SECONDS="${INITIAL_BACKOFF_SECONDS}"
    continue
  fi

  if (( BACKOFF_SECONDS < MAX_BACKOFF_SECONDS )); then
    BACKOFF_SECONDS=$(( BACKOFF_SECONDS * 2 ))
    if (( BACKOFF_SECONDS > MAX_BACKOFF_SECONDS )); then
      BACKOFF_SECONDS="${MAX_BACKOFF_SECONDS}"
    fi
  fi
done
