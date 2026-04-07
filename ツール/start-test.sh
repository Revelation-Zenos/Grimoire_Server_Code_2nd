#!/usr/bin/env bash
# start-test.sh (tool) - Safe test server start script stored in `ツール/`
# This variant resolves the repository root so it works regardless of where the script file is stored.
set -euo pipefail

# Resolve repository root by searching upwards for start.sh (same logic as maintenance scripts)
resolve_repo_root() {
  if [ -n "${REPO_ROOT:-}" ]; then
    if [ -f "${REPO_ROOT}/start.sh" ] || [ -f "${REPO_ROOT}/server.properties" ]; then
      echo "${REPO_ROOT}"
      return 0
    fi
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
  # fallback to current working dir
  echo "$(pwd)"
}
REPO_ROOT=${REPO_ROOT:-$(resolve_repo_root)}
cd "${REPO_ROOT}"

# Prevent accidental double start of Minecraft server by checking for an existing process
FORCE_START=${FORCE_START:-false}
echo "Step: double-start check — scanning for existing 'minecraft_server.jar' processes..."
if [ "$FORCE_START" != "true" ]; then
  # Only block when a Java process is running *from this directory* using this directory's jar.
  pids=$(pgrep -f "minecraft_server.jar" || true)
  found_blocking=""
  nonjava_pids=""
  for pid in $pids; do
    if [ -d "/proc/$pid" ]; then
      exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
      case "$exe" in
        */java|*/javaw)
          # Inspect the command line for '-jar <path>' and compare to this repo's jar
          cmdline=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || true)
          jarArg=""
          set -- $cmdline
          prev=""
          for arg in "$@"; do
            if [ "$prev" = "-jar" ]; then
              jarArg="$arg"
              break
            fi
            prev="$arg"
          done
          if [ -n "$jarArg" ]; then
            jarPath=$(readlink -f "$jarArg" 2>/dev/null || true)
            myJar=$(readlink -f "$PWD/minecraft_server.jar" 2>/dev/null || true)
            if [ -n "$jarPath" ] && [ "$jarPath" = "$myJar" ]; then
              proc_cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
              if [ "$proc_cwd" = "$PWD" ]; then
                found_blocking="$found_blocking $pid"
              else
                # Same jar but different working dir (e.g., subserver); ignore.
                :
              fi
            fi
          else
            nonjava_pids="$nonjava_pids $pid"
          fi
          ;;
        *)
          nonjava_pids="$nonjava_pids $pid"
          ;;
      esac
    fi
  done
  if [ -n "$found_blocking" ]; then
    echo "A Java process using this directory's minecraft_server.jar is already running (PIDs:${found_blocking}). Aborting to avoid double-start." >&2
    echo "If you want to force start regardless, set FORCE_START=true" >&2
    exit 1
  fi
  if [ -n "$nonjava_pids" ]; then
    echo "Note: Non-Java process(es) with name 'minecraft_server.jar' detected (PIDs:${nonjava_pids})." >&2
    echo "This may be a test placeholder; if it's stale, remove it (kill <pid>)." >&2
  fi
  # success message when no blocking Java process found
  if [ -z "$found_blocking" ]; then
    echo "Double-start check: OK — no blocking Java process found."
  fi
else
  echo "FORCE_START=true: skipping double-start check" >&2
fi

# RCON configuration for test server
RCON_PASSWORD_ENV=${RCON_PASSWORD:-}
RCON_PORT_ENV=${RCON_PORT:-25575}
RCON_BIND_ADDR_ENV=${RCON_BIND_ADDR:-}
echo "Step: RCON configuration (test) — checking environment variables..."
if [ -n "${RCON_PASSWORD_ENV}" ]; then
  echo "RCON: applying configuration for test server (port=${RCON_PORT_ENV})..."
  if grep -q "^enable-rcon=" server.properties 2>/dev/null; then
    sed -i "s/^enable-rcon=.*/enable-rcon=true/" server.properties
  else
    echo "enable-rcon=true" >> server.properties
  fi
  if grep -q "^rcon.port=" server.properties 2>/dev/null; then
    sed -i "s/^rcon.port=.*/rcon.port=${RCON_PORT_ENV}/" server.properties
  else
    echo "rcon.port=${RCON_PORT_ENV}" >> server.properties
  fi
  if grep -q "^rcon.password=" server.properties 2>/dev/null; then
    sed -i "s/^rcon.password=.*/rcon.password=${RCON_PASSWORD_ENV//\//\\\//}/" server.properties
  else
    echo "rcon.password=${RCON_PASSWORD_ENV}" >> server.properties
  fi
  echo "RCON enabled in server.properties for test server (rcon.port=${RCON_PORT_ENV})."
else
  echo "RCON: not configured for test server (RCON_PASSWORD not set)."
fi

if [ ! -f minecraft_server.jar ]; then
  echo "Error: minecraft_server.jar not found. Aborting." >&2
  exit 1
fi

# Test settings: reduce memory usage for test environment
JAVA_XMS=${JAVA_XMS:-1G}
JAVA_XMX=${JAVA_XMX:-2G}

# JVM options for test server: enable native access and open Java modules as defaults
JAVA_OPTS=${JAVA_OPTS:---enable-native-access=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.lang.invoke=ALL-UNNAMED --add-opens java.base/jdk.internal.misc=ALL-UNNAMED}

# Start auto-backup after a delay (default 5 minutes)
BACKUP_DELAY_SECONDS=${BACKUP_DELAY_SECONDS:-300}
BACKUP_DIR=${BACKUP_DIR:-"backups_test"}
mkdir -p "${BACKUP_DIR}"
KEEP_LAST=${KEEP_LAST:-3}
export BACKUP_DIR KEEP_LAST

# Test server: enable whitelist and set MOTD to prevent non-admins from joining
# Default MOTD for test server; can be overridden with TEST_MOTD env var
TEST_MOTD=${TEST_MOTD:-"§c現在設定のテスト中 — 管理者のみ入場可"}

# Backup current config before modifying
TIMESTAMP=$(date +%Y%m%d%H%M%S)
cp server.properties "${BACKUP_DIR}/server.properties.pre-test.${TIMESTAMP}.bak"
cp -f whitelist.json "${BACKUP_DIR}/whitelist.json.pre-test.${TIMESTAMP}.bak" || true

# Set whitelist=true and update motd
if grep -q "^white-list=" server.properties 2>/dev/null; then
  sed -i 's/^white-list=.*/white-list=true/' server.properties
else
  echo "white-list=true" >> server.properties
fi
if grep -q "^motd=" server.properties 2>/dev/null; then
  sed -i "s/^motd=.*/motd=${TEST_MOTD//\//\\\//}/" server.properties
else
  echo "motd=${TEST_MOTD}" >> server.properties
fi

echo "Test server mode: whitelist enabled and MOTD set to '${TEST_MOTD}'"

# Merge ops.json into whitelist.json so ops remain allowed on the test server
merge_ops_into_whitelist() {
  if [ ! -f ops.json ]; then
    echo "ops.json not found; skipping ops -> whitelist merge" >&2
    return 0
  fi
  if [ ! -f whitelist.json ]; then
    echo "[]" > whitelist.json
  fi
  if command -v jq >/dev/null 2>&1; then
    tmpfile=$(mktemp)
    if command -v jq >/dev/null 2>&1 && [ -f usercache.json ]; then
      jq -s '
        .[0] // [] as $wh |
        .[1] // [] as $ops |
        .[2] // [] as $cache |
        reduce ($ops[]? // []) as $op ($wh; 
          if any(.uuid == $op.uuid) or any(.name == $op.name) then . 
          else 
            ($cache[]? | select(.uuid == $op.uuid) | .name) as $n // $op.name as $maybeName | . + [{uuid:$op.uuid, name:$maybeName}] 
          end)
      ' whitelist.json ops.json usercache.json > ${tmpfile}
    else
      jq -s '
        .[0] // [] as $wh |
        .[1] // [] as $ops |
        reduce ($ops[]? // []) as $op ($wh; if any(.uuid == $op.uuid) or any(.name == $op.name) then . else . + [{uuid:$op.uuid, name:$op.name}] end)
      ' whitelist.json ops.json > ${tmpfile}
    fi
    mv ${tmpfile} whitelist.json
    echo "Merged ops.json into whitelist.json using jq for test server" >&2
  elif command -v python3 >/dev/null 2>&1; then
    tmpfile=$(mktemp)
    python3 - <<'PY' > ${tmpfile}
import json,sys
try:
    w=json.load(open('whitelist.json'))
except Exception:
    w=[]
try:
    o=json.load(open('ops.json'))
except Exception:
    o=[]
by_uuid=set(x.get('uuid') for x in w if 'uuid' in x)
by_name=set(x.get('name') for x in w if 'name' in x)
cache={}
try:
  with open('usercache.json','r') as f:
    for c in json.load(f):
      if 'uuid' in c and 'name' in c:
        cache[c['uuid']]=c['name']
except Exception:
  cache={}
for op in o:
  u=op.get('uuid')
  n=op.get('name')
  if not n and u and u in cache:
    n=cache[u]
  if u and (u not in by_uuid) and (not n or n not in by_name):
    entry={'uuid':u}
    if n:
      entry['name']=n
    w.append(entry)
    by_uuid.add(u)
    if n:
      by_name.add(n)
  elif n and (n not in by_name):
    entry={'name':n}
    if u:
      entry['uuid']=u
    w.append(entry)
    by_name.add(n)
json.dump(w,sys.stdout,ensure_ascii=False,indent=2)
PY
    mv ${tmpfile} whitelist.json
    echo "Merged ops.json into whitelist.json using python for test server" >&2
  else
    echo "Neither jq nor python3 found; cannot auto-merge ops.json into whitelist.json for test server" >&2
  fi
}

# Run merge now
merge_ops_into_whitelist

if [ -x "scripts/auto_backup.sh" ]; then
  echo "Scheduling auto-backup to start in ${BACKUP_DELAY_SECONDS} seconds (backgrounded)."
  nohup bash -lc "sleep ${BACKUP_DELAY_SECONDS} && bash scripts/auto_backup.sh" >/dev/null 2>&1 &
  echo "Auto-backup scheduler started (pid: $!)."
fi

# Start RCON forwarder (if helper script exists). This mirrors start.sh behavior so
# the forwarder is started for the test server as well.
if [ -x "scripts/start_rcon_forwarder.sh" ]; then
  echo "Starting RCON forwarder helper for test server..."
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --quiet is-active hs-rcon-forwarder.service >/dev/null 2>&1; then
      echo "RCON forwarder systemd service already active; skipping start."
    else
      bash -lc "scripts/start_rcon_forwarder.sh" >/dev/null 2>&1 && echo "RCON forwarder started (helper script)." || echo "Warning: failed to start RCON forwarder helper."
    fi
  else
    bash -lc "scripts/start_rcon_forwarder.sh" >/dev/null 2>&1 && echo "RCON forwarder started (helper script)." || echo "Warning: failed to start RCON forwarder helper."
  fi
fi

echo "Starting test Minecraft server with Xms=${JAVA_XMS}, Xmx=${JAVA_XMX}"
echo "Step: checking for minecraft_server.jar..."
if [ ! -f minecraft_server.jar ]; then
  echo "minecraft_server.jar not found in $(pwd)." >&2
  if [ "${AUTO_FIX_JAR:-false}" = "true" ]; then
    # Prefer exact .jar candidates, but also accept a single prefix-style candidate
    candidates=( $(ls -1 *.jar 2>/dev/null || true) )
    if [ ${#candidates[@]} -eq 1 ]; then
      echo "AUTO_FIX_JAR=true: renaming ${candidates[0]} -> minecraft_server.jar" >&2
      mv "${candidates[0]}" minecraft_server.jar
      echo "AUTO_FIX_JAR: restored 'minecraft_server.jar' from ${candidates[0]}"
    else
      # try prefix-style candidates like minecraft_server.jar.orig or minecraft_server.jar.bak.*
      prefix_candidates=( $(ls -1 minecraft_server.jar.* 2>/dev/null || true) )
      if [ ${#prefix_candidates[@]} -eq 1 ]; then
        echo "AUTO_FIX_JAR=true: restoring single prefix candidate ${prefix_candidates[0]} -> minecraft_server.jar" >&2
        mv "${prefix_candidates[0]}" minecraft_server.jar
        echo "AUTO_FIX_JAR: restored 'minecraft_server.jar' from ${prefix_candidates[0]}"
      else
        echo "AUTO_FIX_JAR=true but could not determine a single candidate (found ${#candidates[@]} '*.jar' and ${#prefix_candidates[@]} 'minecraft_server.jar.*' files)." >&2
        echo "Run: ls -1 minecraft_server.jar*   to inspect available files." >&2
        echo "If you know the correct file, restore it (example):" >&2
        echo "  cp minecraft_server.jar.orig minecraft_server.jar    # restore from .orig" >&2
        echo "  ln -s minecraft_server.jar.orig minecraft_server.jar   # create symlink" >&2
        echo "Or set AUTO_FIX_JAR=true and ensure exactly one candidate matches *.jar or minecraft_server.jar.*" >&2
      fi
    fi
  else
    echo "Error: minecraft_server.jar not found. Suggested actions:" >&2
    echo "  1) place the official server jar as 'minecraft_server.jar' in this directory" >&2
    echo "  2) or: cp minecraft_server.jar.orig minecraft_server.jar" >&2
    echo "  3) or (if you want the script to auto-rename a single candidate): export AUTO_FIX_JAR=true" >&2
    echo "Run 'ls -1 minecraft_server.jar*' to see available files." >&2
    exit 1
  fi
else
  echo "minecraft_server.jar present."
fi

echo "Launching test Minecraft server (Xms=${JAVA_XMS}, Xmx=${JAVA_XMX})..."
logfile=start_test_out.log

# Start detached so shell job-control cannot stop the JVM; prefer setsid+nohup if available.
# Support TEST_FOREGROUND=true for interactive debugging (keeps server in foreground).
# Add a short health-check so an immediate JVM crash is detected and surfaced.
STARTUP_TIMEOUT=${STARTUP_TIMEOUT:-15}  # seconds to wait for "Done (" or process survival
if [ "${TEST_FOREGROUND:-false}" = "true" ]; then
  echo "TEST_FOREGROUND=true: launching server in foreground (attached)." >&2
  exec java ${JAVA_OPTS} -Xms${JAVA_XMS} -Xmx${JAVA_XMX} -jar minecraft_server.jar nogui
else
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid java ${JAVA_OPTS} -Xms${JAVA_XMS} -Xmx${JAVA_XMX} -jar minecraft_server.jar nogui >> "${logfile}" 2>&1 &
  else
    nohup java ${JAVA_OPTS} -Xms${JAVA_XMS} -Xmx${JAVA_XMX} -jar minecraft_server.jar nogui >> "${logfile}" 2>&1 &
  fi
fi

pid=$!
# Record PID atomically so helper scripts can find the server process reliably.
if tmpf=$(mktemp 2>/dev/null); then
  echo "${pid}" > "${tmpf}" && mv "${tmpf}" start_pid.txt || rm -f "${tmpf}"
else
  if ! { echo "${pid}" > start_pid.txt; } 2>/dev/null; then
    echo "Warning: cannot write start_pid.txt (permission denied). Continuing." >&2
  fi
fi

# Short startup health-check: fail fast if the JVM exits immediately.
started_ok=false
for i in $(seq 1 ${STARTUP_TIMEOUT}); do
  sleep 1
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "ERROR: Minecraft server process (pid ${pid}) exited within ${i}s. See ${logfile} for details." >&2
    echo "--- ${logfile} (tail 200) ---" >&2
    tail -n 200 "${logfile}" >&2 || true
    exit 1
  fi
  if grep -q "Done (" "${logfile}" >/dev/null 2>&1; then
    started_ok=true
    break
  fi
done

if [ "${started_ok}" = "true" ]; then
  echo "Started test server (pid ${pid}); logs: ${logfile}"
  exit 0
else
  echo "Warning: server process (pid ${pid}) is running but did not report 'Done' within ${STARTUP_TIMEOUT}s." >&2
  echo "If you see immediate exits locally, re-run with TEST_FOREGROUND=true to get interactive logs." >&2
  echo "--- ${logfile} (tail 200) ---" >&2
  tail -n 200 "${logfile}" >&2 || true
  exit 0
fi
