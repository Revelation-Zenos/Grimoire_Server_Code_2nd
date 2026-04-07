#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PIDFILE="${SCRIPT_DIR}/rcon_forwarder.pid"
PY=${PY:-python3}
if [ -f "${PIDFILE}" ]; then
  if kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
    echo "Forwarder already running (PID $(cat "${PIDFILE}"))"
    exit 0
  else
    rm -f "${PIDFILE}"
  fi
fi
nohup ${PY} "${SCRIPT_DIR}/rcon_forwarder.py" 192.168.11.16 6430 127.0.0.1 16430 >/dev/null 2>&1 &
echo $! > "${PIDFILE}"
echo "Started forwarder (PID $(cat "${PIDFILE}"))"
echo "To run under systemd: scripts/install-systemd-units.sh (requires sudo)"
