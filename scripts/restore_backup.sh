#!/usr/bin/env bash
# restore_backup.sh - Simple world restore tool
# Usage: restore_backup.sh <backup-file> [--force]
# Safety: refuses to restore while server is running unless --force is provided

set -euo pipefail

BACKUP_DIR=${BACKUP_DIR:-"backups"}
DEFAULT_WORLD_DIRS=("Hyouki PublicTestServer" "world")

info() { echo "[restore_backup] $*" >&2; }
err() { echo "[restore_backup] ERROR: $*" >&2; }

usage() {
  cat <<EOF
Usage: restore_backup.sh <backup-file> [--force]

This will create a pre-restore snapshot then extract the backup file into the repo root.
Make sure the server is stopped before restoring. Use --force to override the running check.
EOF
}

if [ "$#" -lt 1 ]; then
  usage
  exit 1
fi

BACKUP_FILE=$1
FORCE=false
DRY_RUN=false
for arg in "${@:2}"; do
  case "$arg" in
    --force)
      FORCE=true
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
  esac
done

if [ "$DRY_RUN" = "true" ]; then
  info "DRY_RUN enabled: no changes will be made."
fi

if [ ! -f "${BACKUP_DIR}/${BACKUP_FILE}" ] && [ ! -f "${BACKUP_FILE}" ]; then
  err "Backup file not found: ${BACKUP_FILE} (checked ${BACKUP_DIR}/${BACKUP_FILE} and ${BACKUP_FILE})"
  exit 1
fi

# Detect running server (minecraft_server.jar)
if pgrep -f "minecraft_server.jar" >/dev/null 2>&1; then
  if [ "$FORCE" = false ]; then
    err "Server appears to be running. Stop the server before restoring to avoid corruption. Use --force to continue at your own risk."
    exit 1
  else
    info "Force restoring while server is running (dangerous)."
  fi
fi

# Determine actual file path
if [ -f "${BACKUP_FILE}" ]; then
  src_file="${BACKUP_FILE}"
else
  src_file="${BACKUP_DIR}/${BACKUP_FILE}"
fi

# Pre-restore snapshot
pre_snapshot_name="${BACKUP_DIR}/pre-restore-$(date +%Y年%m月%d日_%H時%M分%S秒).tar.gz"
info "Creating pre-restore snapshot: ${pre_snapshot_name}"
if [ "$DRY_RUN" = "true" ]; then
  info "DRY_RUN: would tar -czf ${pre_snapshot_name} ${DEFAULT_WORLD_DIRS[*]}"
else
  tar -czf "${pre_snapshot_name}" "${DEFAULT_WORLD_DIRS[@]}"
fi

# Perform restore
info "Restoring from ${src_file}"
# We extract to a temporary directory first
if [ "$DRY_RUN" = "true" ]; then
  info "DRY_RUN: would extract ${src_file} to a temporary directory"
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  tar -xzf "${src_file}" -C "${tmpdir}"
else
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  tar -xzf "${src_file}" -C "${tmpdir}"
fi

# Replace the world directories (move originals aside)
for d in "${DEFAULT_WORLD_DIRS[@]}"; do
  if [ -e "$d" ]; then
    info "Backing up current $d to ${d}.bak"
    if [ "$DRY_RUN" = "true" ]; then
      info "DRY_RUN: would rm -rf ${d}.bak && mv ${d} ${d}.bak"
    else
      rm -rf "${d}.bak" || true
      mv "$d" "${d}.bak"
    fi
  fi
  if [ -e "$tmpdir/$d" ]; then
    info "Restoring $d"
    if [ "$DRY_RUN" = "true" ]; then
      info "DRY_RUN: would mv ${tmpdir}/$d ."
    else
      mv "$tmpdir/$d" .
    fi
  fi
done

info "Restore complete. A pre-restore snapshot was created: ${pre_snapshot_name}"