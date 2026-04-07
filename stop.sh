#!/usr/bin/env bash
set -euo pipefail

# stop.sh - Graceful server stop helper
# Usage: stop.sh [--force] [--timeout=SECONDS]

ORIG_PWD=$(pwd)
cd "$(dirname "$0")"

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

FORCE=false
TIMEOUT=30
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --timeout=*) TIMEOUT="${arg#*=}" ;;
    -h|--help) echo "Usage: stop.sh [--force] [--timeout=SECONDS]" ; exit 0 ;;
    *) ;;
  esac
done

echo "Stopping Minecraft server (timeout=${TIMEOUT}s)"

# Try graceful stop via mcrcon if available and RCON_PASSWORD present
if command -v mcrcon >/dev/null 2>&1 && [ -n "${RCON_PASSWORD:-}" ]; then
  echo "Using mcrcon to request save-all and stop"
  mcrcon -p "${RCON_PASSWORD}" "save-all" || true
  sleep 1
  if [ "${FORCE}" = true ]; then
    echo "--force specified: issuing stop via RCON then forcing process kill if needed"
    mcrcon -p "${RCON_PASSWORD}" stop || true
  else
    mcrcon -p "${RCON_PASSWORD}" stop || true
  fi
  # wait for process to exit
  n=0
  while pgrep -f "minecraft_server.jar" >/dev/null 2>&1; do
    if [ "$n" -ge "$TIMEOUT" ]; then
      echo "Server did not stop after ${TIMEOUT}s"
      break
    fi
    n=$((n+1))
    sleep 1
  done
  if ! pgrep -f "minecraft_server.jar" >/dev/null 2>&1; then
    echo "Server stopped gracefully via RCON."
    rm -f start_pid.txt || true
    exit 0
  fi
fi

# Fallback: if start_pid.txt exists and PID is running, try to SIGTERM it
if [ -f start_pid.txt ]; then
  pid=$(cat start_pid.txt | tr -d '\n' || true)
  if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    echo "Found start_pid.txt with PID $pid — sending TERM"
    kill -TERM "$pid" || true
    n=0
    while [ -d "/proc/$pid" ]; do
      if [ "$n" -ge "$TIMEOUT" ]; then
        echo "PID $pid did not exit after ${TIMEOUT}s"
        break
      fi
      n=$((n+1))
      sleep 1
    done
    if [ ! -d "/proc/$pid" ]; then
      echo "PID $pid exited"
      rm -f start_pid.txt || true
      exit 0
    fi
  fi
fi

# Compatibility fallback: wrapper may have written start_sh_pid.txt — try to find Java child and stop it
if [ -f start_sh_pid.txt ]; then
  spid=$(cat start_sh_pid.txt | tr -d '\n' || true)
  if [ -n "$spid" ] && [ -d "/proc/$spid" ]; then
    child=$(pgrep -P "$spid" -f "java .*minecraft_server.jar" | head -n1 || true)
    if [ -n "$child" ]; then
      echo "Found java child PID $child of wrapper PID $spid — sending TERM"
      kill -TERM "$child" || true
      n=0
      while [ -d "/proc/$child" ]; do
        if [ "$n" -ge "$TIMEOUT" ]; then
          echo "Child PID $child did not exit after ${TIMEOUT}s"
          break
        fi
        n=$((n+1))
        sleep 1
      done
      if [ ! -d "/proc/$child" ]; then
        echo "Child PID $child exited"
        rm -f start_sh_pid.txt || true
        rm -f start_pid.txt || true
        exit 0
      fi
    fi
  fi
fi

# Final fallback: pkill
if pgrep -f "minecraft_server.jar" >/dev/null 2>&1; then
  if [ "${FORCE}" = true ]; then
    echo "Forcing kill of minecraft_server.jar processes"
    pkill -9 -f "minecraft_server.jar" || true
  else
    echo "Attempting polite kill of minecraft_server.jar processes (SIGTERM)"
    pkill -f "minecraft_server.jar" || true
  fi
  # wait
  n=0
  while pgrep -f "minecraft_server.jar" >/dev/null 2>&1; do
    if [ "$n" -ge "$TIMEOUT" ]; then
      echo "Processes did not die after ${TIMEOUT}s"
      break
    fi
    n=$((n+1))
    sleep 1
  done
  if ! pgrep -f "minecraft_server.jar" >/dev/null 2>&1; then
    echo "Server stopped (pkill path)."
    rm -f start_pid.txt || true
    exit 0
  fi
fi

echo "Failed to stop the server cleanly. Check logs/latest.log and start_out.log, and consider running:"
echo "  sudo tail -n 200 logs/latest.log"
echo "  sudo tail -n 200 start_out.log"
exit 1
