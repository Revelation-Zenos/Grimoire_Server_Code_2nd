#!/usr/bin/env bash
set -euo pipefail

# restart.sh - Stop then start the Minecraft server
# Usage: restart.sh [--test] [--force-stop] [--timeout=SECONDS]

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

TEST=false
FORCE=false
TIMEOUT=30
FOREGROUND=false
USE_SCREEN=false
USE_TMUX=false
for arg in "$@"; do
  case "$arg" in
    --test) TEST=true ;;
    --force-stop) FORCE=true ;;
    --timeout=*) TIMEOUT="${arg#*=}" ;;
    --foreground) FOREGROUND=true ;;
    --screen) USE_SCREEN=true ;;
    --tmux) USE_TMUX=true ;;
    -h|--help)
      echo "Usage: restart.sh [--test] [--force-stop] [--timeout=SECONDS] [--foreground|--screen|--tmux]"
      echo "  --foreground  : start server in current terminal (shows JVM console)"
      echo "  --screen      : start server inside a detached screen session (attach with 'screen -r hs' or 'screen -r hs-test')"
      echo "  --tmux        : start server inside a detached tmux session (attach with 'tmux attach -t hs')"
      exit 0 ;;
    *) ;;
  esac
done

# Validate mutually exclusive start modes
if [ "$FOREGROUND" = true ] && { [ "$USE_SCREEN" = true ] || [ "$USE_TMUX" = true ]; }; then
  echo "Error: --foreground is mutually exclusive with --screen or --tmux" >&2
  exit 2
fi
if [ "$USE_SCREEN" = true ] && [ "$USE_TMUX" = true ]; then
  echo "Error: --screen and --tmux are mutually exclusive" >&2
  exit 2
fi

# Stop server (use stop.sh helper)
if [ ! -x ./stop.sh ]; then
  echo "Warning: ./stop.sh not executable or missing — running it with bash"
  if [ "${FORCE}" = true ]; then
    bash stop.sh --force --timeout=${TIMEOUT} || true
  else
    bash stop.sh --timeout=${TIMEOUT} || true
  fi
else
  if [ "${FORCE}" = true ]; then
    ./stop.sh --force --timeout=${TIMEOUT} || true
  else
    ./stop.sh --timeout=${TIMEOUT} || true
  fi
fi

# Wait for processes to exit (give stop.sh TIMEOUT seconds)
n=0
while pgrep -f "minecraft_server.jar" >/dev/null 2>&1; do
  if [ "$n" -ge "$TIMEOUT" ]; then
    echo "Timeout waiting for server to stop after ${TIMEOUT}s"
    break
  fi
  n=$((n+1))
  sleep 1
done
if pgrep -f "minecraft_server.jar" >/dev/null 2>&1; then
  echo "Server processes still running; aborting start unless --force-stop was specified."
  if [ "${FORCE}" != true ]; then
    echo "Use --force-stop to force restart (will SIGKILL processes)."
    exit 1
  else
    echo "Forcing kill of remaining server processes"
    pkill -9 -f "minecraft_server.jar" || true
    sleep 1
  fi
fi

# Start server according to requested mode
if [ "${TEST}" = true ]; then
  LOGFILE="${REPO_ROOT}/start_test_out.log"
  START_CMD="bash start-test.sh"
  SESSION_NAME="hs-test"
else
  LOGFILE="${REPO_ROOT}/start_out.log"
  START_CMD="bash start.sh"
  SESSION_NAME="hs"
fi

cd "${REPO_ROOT}"

if [ "$FOREGROUND" = true ]; then
  echo "Starting server in foreground (attach console to this terminal)."
  # Replace this process with start script so console is visible
  exec bash -lc "${START_CMD}"
fi

if [ "$USE_SCREEN" = true ]; then
  if ! command -v screen >/dev/null 2>&1; then
    echo "screen not installed; install it or use --tmux or --foreground" >&2
    exit 2
  fi
  echo "Starting server inside detached screen session '${SESSION_NAME}' (logging to screenlog.0). Attach with: screen -r ${SESSION_NAME}" 
  screen -S "${SESSION_NAME}" -L -dm bash -lc "cd '${REPO_ROOT}' && exec ${START_CMD}" || true
elif [ "$USE_TMUX" = true ]; then
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux not installed; install it or use --screen or --foreground" >&2
    exit 2
  fi
  echo "Starting server inside detached tmux session '${SESSION_NAME}'. Attach with: tmux attach -t ${SESSION_NAME}"
  tmux new -d -s "${SESSION_NAME}" "cd '${REPO_ROOT}' && exec ${START_CMD}" || true
else
  echo "Starting server in background (using nohup) -> ${LOGFILE}"
  nohup bash -lc "${START_CMD}" > "${LOGFILE}" 2>&1 &
fi

# Wait for a process to appear
n=0
START_OK=false
while [ "$n" -lt "$TIMEOUT" ]; do
  if pgrep -f "minecraft_server.jar" >/dev/null 2>&1; then
    START_OK=true
    break
  fi
  n=$((n+1))
  sleep 1
done

if [ "$START_OK" = true ]; then
  echo "Server process started successfully (check logs for details)."
  if [ "$USE_SCREEN" = true ]; then
    echo "Attach with: screen -r ${SESSION_NAME}"
  elif [ "$USE_TMUX" = true ]; then
    echo "Attach with: tmux attach -t ${SESSION_NAME}"
  else
    echo "Monitor logs/latest.log and ${LOGFILE} for progress."
  fi
  exit 0
else
  echo "Failed to detect server process after starting. See the tail of ${LOGFILE} for clues:" >&2
  if [ -f "${LOGFILE}" ]; then
    tail -n 80 "${LOGFILE}" >&2
  fi
  exit 1
fi
