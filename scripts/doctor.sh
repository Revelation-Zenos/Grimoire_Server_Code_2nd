#!/usr/bin/env bash
# Simple health / safety checks for the Hyouki server repo.
# Non-destructive — safe to run locally or in CI.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
warn=0

require_cmd(){
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] required command not found: $1"
    fail=1
  else
    echo "[OK] $1"
  fi
}

echo "== quick env checks =="
require_cmd jar
require_cmd sha256sum
require_cmd python3
require_cmd jq || warn=1
require_cmd mcrcon || warn=1

echo "\n== repository safety checks =="
# Ensure server.properties is ignored
if git check-ignore -q server.properties; then
  echo "[OK] server.properties is gitignored"
else
  echo "[ERROR] server.properties is not in .gitignore — remove secrets from repo and add to .gitignore"
  fail=1
fi

# Scan for obvious committed secrets (non-exhaustive)
if grep -nH "^\s*rcon.password=\(REPLACE_ME\)\?" server.properties >/dev/null 2>&1; then
  # If file exists, ensure it contains placeholder only
  if grep -nH "^\s*rcon.password=\s*REPLACE_ME\s*$" server.properties >/dev/null 2>&1; then
    echo "[OK] server.properties contains placeholder for rcon.password"
  else
    echo "[ERROR] server.properties contains an RCON password value — rotate and remove from repo"
    fail=1
  fi
fi
if grep -nH "management-server-secret=REPLACE_ME" server.properties >/dev/null 2>&1; then
  echo "[OK] management-server-secret is sanitized"
fi

# auto_backup DRY_RUN behaviour: ensure DRY_RUN does not delete files
echo "\n== auto_backup DRY-RUN smoke =="
set +e
RUN_ONCE=true DRY_RUN=true BACKUP_DIR=backups_test bash scripts/auto_backup.sh >/tmp/auto_backup_dryrun.out 2>&1
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "[ERROR] auto_backup.sh DRY_RUN failed (exit ${rc}) — check /tmp/auto_backup_dryrun.out"
  fail=1
else
  if grep -q "DRY_RUN: would prune" /tmp/auto_backup_dryrun.out; then
    echo "[OK] auto_backup.sh DRY_RUN lists prune candidates and did not delete files"
  else
    echo "[WARN] auto_backup.sh DRY_RUN did not explicitly list prune candidates — inspect output"
    warn=1
  fi
fi

# Basic operational guidance check
if [ -f server.properties ] && ! grep -q "RCON_PASSWORD" .github >/dev/null 2>&1; then
  echo "[INFO] Ensure you set RCON_PASSWORD and MANAGEMENT_SERVER_SECRET via environment (not in repo)."
fi

echo "\n== result =="
if [ $fail -ne 0 ]; then
  echo "One or more ERROR checks failed. Fix before deploying."
  exit 2
fi
if [ $warn -ne 0 ]; then
  echo "Some WARN checks — review recommendations."
  exit 1
fi

echo "All quick checks passed."
exit 0
