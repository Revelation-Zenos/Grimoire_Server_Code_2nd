#!/usr/bin/env bash
# auto_backup.sh - Minecraft world auto-backup script
# Default: perform backup every 5 minutes; safe shutdown mode: uses rcon/screen/tmux save-all/save-off/save-on when possible

set -euo pipefail

# Config
INTERVAL_MINUTES=${INTERVAL_MINUTES:-5}
BACKUP_DIR=${BACKUP_DIR:-"backups"}
KEEP_LAST=${KEEP_LAST:-7}
# Prefix for backup filenames (can be overridden with env var). User-request: default is "Grimoire_Server".
BACKUP_PREFIX=${BACKUP_PREFIX:-"Grimoire_Server"}
DEFAULT_WORLD_DIRS=("Hyouki PublicTestServer" "world")

# Parse simple CLI flags --once and --dry-run
for arg in "$@"; do
  case "$arg" in
    --once)
      RUN_ONCE=true
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
  esac
done

# Maximum seconds to wait after issuing save-off
SAVE_WAIT_SECONDS=${SAVE_WAIT_SECONDS:-2}

# Tools to send server commands
# If RCON_* environment vars are set and mcrcon is installed, mcrcon will be used
# If SCREEN_SESSION is set and screen is running, screen will be used to send commands
# If TMUX_SESSION is set and tmux is running, tmux send-keys will be used

info() { echo "[auto_backup] $*" >&2; }
err() { echo "[auto_backup] ERROR: $*" >&2; }

# Ensure backup directory exists
mkdir -p "${BACKUP_DIR}"

# Prevent duplicate instances by using a pidfile in the backup directory
PIDFILE="${BACKUP_DIR}/auto_backup.pid"
if [ -f "${PIDFILE}" ]; then
  existing_pid=$(cat "${PIDFILE}" 2>/dev/null || true)
  if [ -n "${existing_pid}" ]; then
    if kill -0 "${existing_pid}" >/dev/null 2>&1; then
      info "Auto-backup already running (pid ${existing_pid}), exiting."
      exit 0
    else
      info "Removing stale pidfile ${PIDFILE}."
      rm -f "${PIDFILE}" || true
    fi
  fi
fi
echo $$ > "${PIDFILE}"
trap 'rm -f "${PIDFILE}"' EXIT

# Detect world directories present
WORLD_DIRS=()
for d in "${DEFAULT_WORLD_DIRS[@]}"; do
  if [ -e "$d" ]; then
    WORLD_DIRS+=("$d")
  fi
done

if [ ${#WORLD_DIRS[@]} -eq 0 ]; then
  err "No world directories found. Exiting."
  exit 1
fi

# Helpers to issue server commands
send_rcon_cmd() {
  local cmd=$1
  if command -v mcrcon >/dev/null 2>&1; then
    if [ -n "${RCON_PASSWORD:-}" ]; then
      # mcrcon automatically reads host/port from env or args; default to localhost:25575
      if [ -n "${RCON_HOST:-}" ] && [ -n "${RCON_PORT:-}" ]; then
        mcrcon -H "${RCON_HOST}" -P "${RCON_PORT}" -p "${RCON_PASSWORD}" "$cmd"
      else
        mcrcon -p "${RCON_PASSWORD}" "$cmd"
      fi
      return $?
    else
      err "RCON_PASSWORD is not set; cannot use rcon."
      return 2
    fi
  else
    err "mcrcon not installed; cannot use rcon."
    return 2
  fi
}

send_screen_cmd() {
  local cmd=$1
  if [ -n "${SCREEN_SESSION:-}" ]; then
    if command -v screen >/dev/null 2>&1; then
      screen -S "${SCREEN_SESSION}" -p 0 -X stuff "$cmd\n"
      return $?
    else
      err "screen not installed"
      return 2
    fi
  else
    err "SCREEN_SESSION is not set"
    return 2
  fi
}

send_tmux_cmd() {
  local cmd=$1
  if [ -n "${TMUX_SESSION:-}" ]; then
    if command -v tmux >/dev/null 2>&1; then
      tmux send-keys -t "${TMUX_SESSION}" "$cmd" Enter
      return $?
    else
      err "tmux not installed"
      return 2
    fi
  else
    err "TMUX_SESSION is not set"
    return 2
  fi
}

# Performs a safe-save sequence: save-all, save-off (if supported), then return save-on
safe_save_sequence() {
  info "Requesting server to save world(s)..."
  if send_rcon_cmd "save-all" 2>/dev/null; then
    :
  else
    send_screen_cmd "save-all" 2>/dev/null || send_tmux_cmd "save-all" 2>/dev/null || info "save-all not sent (no console method)."
  fi

  # If rcon/screen/tmux supports save-off, do it to avoid partial writes during copying
  if send_rcon_cmd "save-off" 2>/dev/null; then
    info "save-off via rcon"
  else
    if send_screen_cmd "save-off" 2>/dev/null || send_tmux_cmd "save-off" 2>/dev/null; then
      info "save-off via console"
    else
      info "save-off not sent (no console method). Proceeding without save-off."
    fi
  fi

  sleep ${SAVE_WAIT_SECONDS}
}

# Restore saving after backup
safe_save_restore() {
  if send_rcon_cmd "save-on" 2>/dev/null; then
    info "save-on via rcon"
  else
    if send_screen_cmd "save-on" 2>/dev/null || send_tmux_cmd "save-on" 2>/dev/null; then
      info "save-on via console"
    else
      info "save-on not sent (no console method)."
    fi
  fi
}

# Compose backup filename
timestamp() { date +"%Y年%m月%d日_%H時%M分%S秒"; }

perform_backup() {
  local ts
  ts=$(timestamp)
  local filename="${BACKUP_DIR}/${BACKUP_PREFIX}-${ts}.tar.gz"
  info "Backing up: ${WORLD_DIRS[*]} -> ${filename}"

  safe_save_sequence

  # Archive only the world directories
  tar -czf "${filename}" "${WORLD_DIRS[@]}"
  local exit_code=$?

  safe_save_restore

  if [ $exit_code -ne 0 ]; then
    err "tar failed with exit code $exit_code"
    return $exit_code
  fi

  info "Backup completed: ${filename}"

  # Prune old backups, keep last $KEEP_LAST
  prune_old_backups

  return 0
}

prune_old_backups() {
  local keep=$KEEP_LAST
  local files
  # Accept both the new `${BACKUP_PREFIX}-` prefix and legacy `hs-backup-` files for compatibility.
  mapfile -t files < <(find "${BACKUP_DIR}" -maxdepth 1 -type f \( -name "${BACKUP_PREFIX}-*.tar.gz" -o -name "hs-backup-*.tar.gz" \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
  if [ ${#files[@]} -le $keep ]; then
    return 0
  fi
  # If DRY_RUN is enabled, only list candidates for pruning and do NOT delete anything.
  if [ "${DRY_RUN:-false}" = "true" ]; then
    info "DRY_RUN: would prune the following backups (keeping last ${keep}):"
    for i in $(seq $keep $(( ${#files[@]} - 1))); do
      info "  ${files[$i]}"
    done
    return 0
  fi
  for i in $(seq $keep $(( ${#files[@]} - 1))); do
    local f=${files[$i]}
    info "Pruning old backup $f"
    rm -f -- "$f"
  done
}

# CLI flags and environment options
DRY_RUN=${DRY_RUN:-false}
RUN_ONCE=${RUN_ONCE:-false}

# Main loop: runs in the background until killed
info "Starting auto-backup: interval ${INTERVAL_MINUTES} minute(s), keep ${KEEP_LAST} backups"
info "World dirs: ${WORLD_DIRS[*]}"

if [ "$DRY_RUN" = "true" ]; then
  info "DRY_RUN enabled: no backups will be written"
fi

if [ "$RUN_ONCE" = "true" ]; then
  info "RUN_ONCE enabled: performing a single backup then exiting"
  if [ "$DRY_RUN" = "true" ]; then
    info "DRY_RUN: would perform safe_save_sequence and tar to filename"
  else
    perform_backup || err "Backup failed"
  fi
  exit 0
fi

while true; do
  if [ "$DRY_RUN" = "true" ]; then
    info "DRY_RUN: would perform safe_save_sequence and tar to file"
    prune_old_backups
  else
    if perform_backup; then
      :
    else
      err "Backup failed; will retry after next interval"
    fi
  fi
  sleep "${INTERVAL_MINUTES}m"
done
