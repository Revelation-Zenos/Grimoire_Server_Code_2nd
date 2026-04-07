#!/usr/bin/env bash
# Wrapper that delegates to the tools copy of start-test to allow relocating the script file.
# This keeps backwards compatibility for callers who run ./start-test.sh in the repo root.

DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Delegating to tools/start-test.sh (test server start)..."
exec bash "$DIR/ツール/start-test.sh" "$@"

# RCON configuration for test server
RCON_PASSWORD_ENV=${RCON_PASSWORD:-}
RCON_PORT_ENV=${RCON_PORT:-25575}
RCON_BIND_ADDR_ENV=${RCON_BIND_ADDR:-}
if [ -n "${RCON_PASSWORD_ENV}" ]; then
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
  # Set rcon.bind-address from RCON_BIND_ADDR if provided, else use server-ip if set to avoid 0.0.0.0 binding
  if [ -n "${RCON_BIND_ADDR_ENV}" ]; then
    if grep -q "^rcon.bind-address=" server.properties 2>/dev/null; then
      sed -i "s/^rcon.bind-address=.*/rcon.bind-address=${RCON_BIND_ADDR_ENV//\//\\\//}/" server.properties
    else
      echo "rcon.bind-address=${RCON_BIND_ADDR_ENV}" >> server.properties
    fi
    echo "rcon.bind-address set to ${RCON_BIND_ADDR_ENV}"
  else
    if grep -q "^server-ip=" server.properties 2>/dev/null; then
      sip=$(grep -m1 "^server-ip=" server.properties | cut -d'=' -f2-)
      if [ -n "${sip}" ]; then
        if grep -q "^rcon.bind-address=" server.properties 2>/dev/null; then
          sed -i "s/^rcon.bind-address=.*/rcon.bind-address=${sip//\//\\\//}/" server.properties
        else
          echo "rcon.bind-address=${sip}" >> server.properties
        fi
        echo "rcon.bind-address set to server-ip ${sip}"
      fi
    fi
  fi
  echo "RCON enabled in server.properties for test server (rcon.port=${RCON_PORT_ENV})."
fi

if [ ! -f minecraft_server.jar ]; then
  echo "Note: minecraft_server.jar not present yet; delegating to tools/start-test.sh which may attempt recovery if AUTO_FIX_JAR is enabled." >&2
fi

# Test settings: reduce memory usage for test environment
JAVA_XMS=${JAVA_XMS:-1G}
JAVA_XMX=${JAVA_XMX:-4G}

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
fi

# Start RCON forwarder (if helper script exists). This mirrors start.sh behavior so
# the forwarder is started for the test server as well.
if [ -x "scripts/start_rcon_forwarder.sh" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl --quiet is-active hs-rcon-forwarder.service >/dev/null 2>&1; then
      bash -lc "scripts/start_rcon_forwarder.sh" >/dev/null 2>&1 || true
    fi
  else
    bash -lc "scripts/start_rcon_forwarder.sh" >/dev/null 2>&1 || true
  fi
fi

echo "Starting test Minecraft server with Xms=${JAVA_XMS}, Xmx=${JAVA_XMX}"
if [ ! -f minecraft_server.jar ]; then
  echo "minecraft_server.jar not found in $(pwd)." >&2
  if [ "${AUTO_FIX_JAR:-false}" = "true" ]; then
    candidates=( $(ls -1 *.jar 2>/dev/null || true) )
    if [ ${#candidates[@]} -eq 1 ]; then
      echo "AUTO_FIX_JAR=true: renaming ${candidates[0]} -> minecraft_server.jar" >&2
      mv "${candidates[0]}" minecraft_server.jar
    else
      echo "AUTO_FIX_JAR=true but found ${#candidates[@]} candidates: ${candidates[*]}. Rename manually or set AUTO_FIX_JAR to false." >&2
    fi
  else
    echo "Error: minecraft_server.jar not found. Set AUTO_FIX_JAR=true to auto-rename a single .jar candidate or place the correct jar in this directory." >&2
    exit 1
  fi
fi

echo "Launching test Minecraft server (Xms=${JAVA_XMS}, Xmx=${JAVA_XMX})..."
# Record PID so helper scripts can find the server process reliably
echo $$ > start_pid.txt
# Start the test Minecraft server and capture output for diagnostics
java ${JAVA_OPTS} -Xms${JAVA_XMS} -Xmx${JAVA_XMX} -jar minecraft_server.jar >> start_test_out.log 2>&1
rc=$?
echo "$(date '+%F %T') Test Minecraft server exited with code ${rc}" >> start_test_out.log
if [ ${rc} -ne 0 ]; then
  echo "Minecraft server process exited with code ${rc}; check start_test_out.log and logs/latest.log for details." >&2
  exit ${rc}
fi
exit 0
