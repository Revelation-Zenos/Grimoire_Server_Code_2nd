#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PIDFILE="${SCRIPT_DIR}/rcon_forwarder.pid"
if [ ! -f "${PIDFILE}" ]; then
  echo "No PID file; forwarder not running?"
  exit 0
fi
PID=$(cat "${PIDFILE}")
if kill -0 ${PID} 2>/dev/null; then
  kill ${PID}
  echo "Stopped forwarder (PID ${PID})"
else
  echo "Forwarder process not found; removing stale PID file"
fi
rm -f "${PIDFILE}"
