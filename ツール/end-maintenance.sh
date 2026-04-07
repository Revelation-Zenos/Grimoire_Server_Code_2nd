#!/usr/bin/env bash
# end-maintenance.sh - Restore server config from pre-maintenance backups (if present)
set -euo pipefail

ORIG_PWD=$(pwd)
cd "$(dirname "$0")"

# Resolve repo root like in start-maintenance.sh
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

BACKUP_DIR=${BACKUP_DIR:-"backups"}

usage() {
  cat <<EOF
Usage: end-maintenance.sh [--timestamp YYYYMMDDHHMMSS] [--force]

This attempts to restore the most recent pre-maintenance backups for server.properties and whitelist.json.
If --timestamp is provided, the script will restore those specific files. Otherwise, it picks the most-recent pre-maintenance backup
where the `motd=` value differs from the current `server.properties` value (to avoid restoring the maintenance motd again).
Use --force to restore the latest pre-maintenance backup regardless of motd value.
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
    -h|--help)
      usage; exit 0
      ;;
    --restart)
      RESTART=true
      ;;
    *) ;;
  esac
done

if [ -n "${TS}" ]; then
  if [ -f "${BACKUP_DIR}/server.properties.pre-maintenance.${TS}.bak" ]; then
    echo "Restoring server.properties from timestamp ${TS}"
    cp "${BACKUP_DIR}/server.properties.pre-maintenance.${TS}.bak" server.properties
  else
    echo "Server properties backup for ${TS} not found in ${BACKUP_DIR}" >&2
  fi
  if [ -f "${BACKUP_DIR}/whitelist.json.pre-maintenance.${TS}.bak" ]; then
    cp "${BACKUP_DIR}/whitelist.json.pre-maintenance.${TS}.bak" whitelist.json
  else
    echo "Whitelist backup for ${TS} not found in ${BACKUP_DIR}" >&2
  fi
  exit 0
fi

# Attempt to find latest pre-maintenance backups
# If not forced, prefer the latest backup where motd differs from current motd (to avoid reapplying maintenance motd)
CUR_MOTD=""
if [ -f server.properties ]; then
  CUR_MOTD=$(grep -m1 '^motd=' server.properties 2>/dev/null | cut -d'=' -f2- || true)
fi
svp=""
if [ "${FORCE}" = true ]; then
  svp=$(ls -1t ${BACKUP_DIR}/server.properties.pre-maintenance.*.bak 2>/dev/null | head -n1 || true)
else
  for f in $(ls -1t ${BACKUP_DIR}/server.properties.pre-maintenance.*.bak 2>/dev/null || true); do
    bmotd=$(grep -m1 '^motd=' "${f}" 2>/dev/null | cut -d'=' -f2- || true)
    if [ "${bmotd}" != "${CUR_MOTD}" ] && [ -n "${bmotd}" ]; then
      svp="${f}"
      break
    fi
  done
  # Fallback: no matching non-maintenance backup found -> pick latest
  if [ -z "${svp}" ]; then
    svp=$(ls -1t ${BACKUP_DIR}/server.properties.pre-maintenance.*.bak 2>/dev/null | head -n1 || true)
  fi
fi
wl=$(ls -1t ${BACKUP_DIR}/whitelist.json.pre-maintenance.*.bak 2>/dev/null | head -n1 || true)

if [ -n "${svp}" ]; then
  echo "Restoring server.properties from ${svp}"
  cp "${svp}" server.properties
  # Ensure motd is correctly restored even if other processes changed it earlier.
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
  echo "No pre-maintenance server.properties backup found in ${BACKUP_DIR}" >&2
fi
if [ -n "${wl}" ]; then
  echo "Restoring whitelist.json from ${wl}"
  cp "${wl}" whitelist.json
else
  echo "No pre-maintenance whitelist.json backup found in ${BACKUP_DIR}" >&2
fi

# Show resulting motd from restored server.properties
if [ -f server.properties ]; then
  NEW_MOTD=$(grep -m1 '^motd=' server.properties 2>/dev/null | cut -d'=' -f2- || true)
  echo "Restored motd: ${NEW_MOTD}" >&2
fi

if [ "${RESTART}" = true ]; then
  echo "Restarting server to apply changes..."
  # attempt graceful stop via rcon; fallback to pkill
  if command -v mcrcon >/dev/null 2>&1 && [ -n "${RCON_PASSWORD:-}" ]; then
    mcrcon -p "${RCON_PASSWORD}" stop || true
    sleep 3
  fi
  if pgrep -f "minecraft_server.jar" >/dev/null 2>&1; then
    pkill -f "minecraft_server.jar" || true
    sleep 3
  fi
  (cd "${REPO_ROOT}" && nohup bash start.sh > start_out.log 2>&1 &)
  echo "Server restart requested. Check logs/latest.log and start_out.log for details." >&2
fi
echo "Restore attempted. Please review server.properties and restart the server if needed." >&2
