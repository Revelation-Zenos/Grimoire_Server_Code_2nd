#!/usr/bin/env bash
# end-test.sh - Restore server config from pre-test backups (if present)
# Usage: end-test.sh [--timestamp YYYYMMDDHHMMSS] [--force] [--restart]
set -euo pipefail

ORIG_PWD=$(pwd)
cd "$(dirname "$0")"

# Resolve repo root like in other tools
resolve_repo_root() {
  if [ -n "${REPO_ROOT:-}" ]; then
    if [ -f "${REPO_ROOT}/start.sh" ] || [ -f "${REPO_ROOT}/server.properties" ]; then
      echo "${REPO_ROOT}"
      return 0
    fi
  fi
  if [ -f "${ORIG_PWD}/start.sh" ] || [ -f "${ORIG_PWD}/server.properties" ]; then
    echo "${ORIG_PWD}"
    return 0
  fi
  local d
  d=$(cd "$(dirname "$0")" && pwd)
  while [ "$d" != "/" ]; do
    if [ -f "$d/start.sh" ] || [ -f "$d/server.properties" ]; then
      echo "$d"
      return 0
    fi
    d=$(dirname "$d")
  done
  echo "$(pwd)"
}
REPO_ROOT=${REPO_ROOT:-$(resolve_repo_root)}
cd "$REPO_ROOT"

# Default backup directory for test runs
BACKUP_DIR=${BACKUP_DIR:-"backups_test"}

usage() {
  cat <<EOF
Usage: end-test.sh [--timestamp YYYYMMDDHHMMSS] [--force] [--restart]

This attempts to restore the most recent pre-test backups for server.properties and whitelist.json.
If --timestamp is provided, the script will restore those specific files from ${BACKUP_DIR}.
Use --force to restore the latest pre-test backup regardless of motd value.
--restart will attempt to restart the server after restoring.
EOF
}

TS=""
FORCE=false
RESTART=false
for arg in "$@"; do
  case "$arg" in
    --timestamp=*)
      TS="${arg#*=}"
      ;;
    --force)
      FORCE=true
      ;;
    --restart)
      RESTART=true
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *) ;;
  esac
done

# If TS provided, restore specific files
if [ -n "${TS}" ]; then
  if [ -f "${BACKUP_DIR}/server.properties.pre-test.${TS}.bak" ]; then
    echo "Restoring server.properties from timestamp ${TS}"
    cp "${BACKUP_DIR}/server.properties.pre-test.${TS}.bak" server.properties
    bmotd=$(grep -m1 '^motd=' "${BACKUP_DIR}/server.properties.pre-test.${TS}.bak" 2>/dev/null | cut -d'=' -f2- || true)
    if [ -n "${bmotd}" ]; then
      if grep -q '^motd=' server.properties 2>/dev/null; then
        sed -i "s/^motd=.*/motd=${bmotd//\//\\\//}/" server.properties
      else
        echo "motd=${bmotd}" >> server.properties
      fi
      echo "Restored motd: ${bmotd}" >&2
    else
      echo "No motd found in backup; leaving motd unchanged." >&2
    fi
  else
    echo "server.properties pre-test backup for ${TS} not found in ${BACKUP_DIR}" >&2
  fi
  if [ -f "${BACKUP_DIR}/whitelist.json.pre-test.${TS}.bak" ]; then
    echo "Restoring whitelist.json from timestamp ${TS}"
    cp "${BACKUP_DIR}/whitelist.json.pre-test.${TS}.bak" whitelist.json
  else
    echo "Whitelist pre-test backup for ${TS} not found in ${BACKUP_DIR}" >&2
  fi
  exit 0
fi

# No timestamp: find latest matching backup
CUR_MOTD=""
if [ -f server.properties ]; then
  CUR_MOTD=$(grep -m1 '^motd=' server.properties 2>/dev/null | cut -d'=' -f2- || true)
fi

# Find latest candidate backups (unchanged behavior)
svp=""
if [ "${FORCE}" = true ]; then
  svp=$(ls -1t ${BACKUP_DIR}/server.properties.pre-test.*.bak 2>/dev/null | head -n1 || true)
else
  for f in $(ls -1t ${BACKUP_DIR}/server.properties.pre-test.*.bak 2>/dev/null || true); do
    bmotd=$(grep -m1 '^motd=' "${f}" 2>/dev/null | cut -d'=' -f2- || true)
    # prefer a backup whose motd differs from current motd (to avoid reapplying test motd)
    if [ "${bmotd}" != "${CUR_MOTD}" ] && [ -n "${bmotd}" ]; then
      svp="${f}"
      break
    fi
  done
  # Fallback: pick latest
  if [ -z "${svp}" ]; then
    svp=$(ls -1t ${BACKUP_DIR}/server.properties.pre-test.*.bak 2>/dev/null | head -n1 || true)
  fi
fi
wl=$(ls -1t ${BACKUP_DIR}/whitelist.json.pre-test.*.bak 2>/dev/null | head -n1 || true)

# --- Robust server-stop utilities ---
STOP_TIMEOUT=${STOP_TIMEOUT:-30}   # seconds to wait for graceful stop
STOP_TERM=${STOP_TERM:-10}        # seconds to wait after SIGTERM before SIGKILL

# Prefer start_pid.txt when present and validate it refers to this repo's jar
find_server_pid() {
  # prefer recorded PID
  if [ -f start_pid.txt ]; then
    pid=$(cat start_pid.txt 2>/dev/null || true)
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      # validate that pid is running this repo's jar
      cmdline=$(tr '\0' ' ' < /proc/${pid}/cmdline 2>/dev/null || true)
      if echo "${cmdline}" | grep -q "minecraft_server.jar"; then
        # ensure the jar path (if present) matches this repo's jar when possible
        jarArg=""
        set -- ${cmdline}
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "-jar" ]; then
            jarArg="$arg"
            break
          fi
          prev="$arg"
        done
        if [ -z "${jarArg}" ] || [ "$(readlink -f "${jarArg}" 2>/dev/null)" = "$(readlink -f "${PWD}/minecraft_server.jar" 2>/dev/null)" ]; then
          echo "${pid}"
          return 0
        fi
      fi
    fi
  fi
  # fallback: search for a java -jar running this repo's jar
  for pid in $(pgrep -f "minecraft_server.jar" 2>/dev/null || true); do
    if [ -d "/proc/${pid}" ]; then
      cmdline=$(tr '\0' ' ' < /proc/${pid}/cmdline 2>/dev/null || true)
      if echo "${cmdline}" | grep -q "-jar"; then
        jarArg=""
        set -- ${cmdline}
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "-jar" ]; then
            jarArg="$arg"
            break
          fi
          prev="$arg"
        done
        jarPath=$(readlink -f "${jarArg}" 2>/dev/null || true)
        myJar=$(readlink -f "${PWD}/minecraft_server.jar" 2>/dev/null || true)
        if [ -n "${jarPath}" ] && [ "${jarPath}" = "${myJar}" ]; then
          echo "${pid}"
          return 0
        fi
      fi
    fi
  done
  return 1
}

stop_server() {
  target_pid="$1"
  echo "Attempting graceful stop of server (pid ${target_pid})" >&2
  # Try RCON stop if possible
  if command -v mcrcon >/dev/null 2>&1 && [ -n "${RCON_PASSWORD:-}" ]; then
    echo "-> sending 'stop' over RCON (mcrcon)" >&2
    mcrcon -p "${RCON_PASSWORD}" stop || true
  fi
  # Send SIGINT then wait
  kill -INT "${target_pid}" 2>/dev/null || true
  for i in $(seq 1 ${STOP_TIMEOUT}); do
    sleep 1
    if ! kill -0 "${target_pid}" 2>/dev/null; then
      echo "Server (pid ${target_pid}) exited gracefully." >&2
      return 0
    fi
  done
  echo "Server did not exit after ${STOP_TIMEOUT}s; sending SIGTERM." >&2
  kill -TERM "${target_pid}" 2>/dev/null || true
  for i in $(seq 1 ${STOP_TERM}); do
    sleep 1
    if ! kill -0 "${target_pid}" 2>/dev/null; then
      echo "Server (pid ${target_pid}) terminated after SIGTERM." >&2
      return 0
    fi
  done
  echo "SIGTERM did not stop server; sending SIGKILL." >&2
  kill -KILL "${target_pid}" 2>/dev/null || true
  sleep 1
  if ! kill -0 "${target_pid}" 2>/dev/null; then
    echo "Server (pid ${target_pid}) killed." >&2
    return 0
  fi
  echo "Failed to stop server (pid ${target_pid})." >&2
  return 1
}

stop_rcon_forwarder() {
  # Prefer explicit pidfile from scripts/start_rcon_forwarder.sh, then systemd, then helper script, finally pkill.
  if [ -f "scripts/rcon_forwarder.pid" ]; then
    pid=$(cat scripts/rcon_forwarder.pid 2>/dev/null || true)
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      echo "Stopping rcon forwarder (pid ${pid}) from scripts/rcon_forwarder.pid" >&2
      kill -TERM "${pid}" 2>/dev/null || true
      for i in "." ".." "..."; do
        sleep 1
        if ! kill -0 "${pid}" 2>/dev/null; then
          break
        fi
      done
      if kill -0 "${pid}" 2>/dev/null; then
        kill -KILL "${pid}" 2>/dev/null || true
      fi
      rm -f scripts/rcon_forwarder.pid || true
      return 0
    else
      rm -f scripts/rcon_forwarder.pid || true
    fi
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl --quiet is-active hs-rcon-forwarder.service >/dev/null 2>&1; then
    echo "Stopping hs-rcon-forwarder.service via systemctl" >&2
    systemctl stop hs-rcon-forwarder.service || true
    return 0
  fi
  if [ -x "scripts/stop_rcon_forwarder.sh" ]; then
    echo "Stopping rcon forwarder via scripts/stop_rcon_forwarder.sh" >&2
    bash -lc "scripts/stop_rcon_forwarder.sh" || true
    return 0
  fi
  # best-effort: pkill any helper process by script name or commandline
  pkill -f rcon_forwarder.py || true
  pkill -f hs-rcon-forwarder || true
}

# If server is running, require --force or --restart to perform restore; prefer stopping the server first.
running_pid=$(find_server_pid || true)
if [ -n "${running_pid}" ]; then
  echo "Detected running test server (pid ${running_pid})." >&2
  if [ "${RESTART}" = true ] || [ "${FORCE}" = true ]; then
    stop_rcon_forwarder || true
    if ! stop_server "${running_pid}"; then
      echo "Warning: could not stop server (pid ${running_pid}). Aborting restore." >&2
      exit 1
    fi
    rm -f start_pid.txt || true
  else
    echo "Refusing to restore while test server is running. Use --restart (recommended) or --force to stop and restore." >&2
    exit 1
  fi
fi

# Perform restore (server is stopped or was not running)
if [ -n "${svp}" ]; then
  echo "Restoring server.properties from ${svp}"
  cp "${svp}" server.properties
  bmotd=$(grep -m1 '^motd=' "${svp}" 2>/dev/null | cut -d'=' -f2- || true)
  if [ -n "${bmotd}" ]; then
    if grep -q '^motd=' server.properties 2>/dev/null; then
      sed -i "s/^motd=.*/motd=${bmotd//\//\\\//}/" server.properties
    else
      echo "motd=${bmotd}" >> server.properties
    fi
    echo "Restored motd: ${bmotd}" >&2
  else
    echo "No motd found in ${svp}; leaving motd unchanged." >&2
  fi
else
  echo "No pre-test server.properties backup found in ${BACKUP_DIR}" >&2
fi

if [ -n "${wl}" ]; then
  echo "Restoring whitelist.json from ${wl}"
  cp "${wl}" whitelist.json
else
  echo "No pre-test whitelist.json backup found in ${BACKUP_DIR}" >&2
fi

if [ "${RESTART}" = true ]; then
  echo "Restarting server to apply changes..."
  (cd "${REPO_ROOT}" && nohup bash start.sh > start_out.log 2>&1 &)
  echo "Server restart requested. Check logs/latest.log and start_out.log for details." >&2
fi

# Cleanup
rm -f start_pid.txt || true

echo "Restore attempted. Please review server.properties and restart the server if needed." >&2
