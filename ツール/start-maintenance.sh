#!/usr/bin/env bash
# start-maintenance.sh - Start server in maintenance mode (whitelist enabled + MOTD change)
set -euo pipefail

ORIG_PWD=$(pwd)
cd "$(dirname "$0")"

# Resolve repository root by searching upwards for start.sh
resolve_repo_root() {
  # 1) honor explicit REPO_ROOT if valid
  if [ -n "${REPO_ROOT:-}" ]; then
    if [ -f "${REPO_ROOT}/start.sh" ] || [ -f "${REPO_ROOT}/server.properties" ]; then
      echo "${REPO_ROOT}"
      return 0
    fi
  fi
  # 2) prefer the original current working directory if it looks like the repo root
  if [ -f "${ORIG_PWD}/start.sh" ] || [ -f "${ORIG_PWD}/server.properties" ]; then
    echo "${ORIG_PWD}"
    return 0
  fi
  # 3) search upwards from the script's directory
  local d
  d=$(cd "$(dirname "$0")" && pwd)
  while [ "$d" != "/" ]; do
    if [ -f "$d/start.sh" ] || [ -f "$d/server.properties" ]; then
      echo "$d"
      return 0
    fi
    d=$(dirname "$d")
  done
  # last resort: return current working directory
  echo "$(pwd)"
}
REPO_ROOT=${REPO_ROOT:-$(resolve_repo_root)}
cd "$REPO_ROOT"

BACKUP_DIR=${BACKUP_DIR:-"backups"}
mkdir -p "${BACKUP_DIR}"

usage() {
  cat <<EOF
Usage: start-maintenance.sh [--add-admins "name1,name2"] [--motd "message"] [--no-restart]

This enables whitelist, sets MOTD to indicate maintenance, and starts the server via start.sh.
It creates backups of server.properties and whitelist.json in ${BACKUP_DIR}/.
--add-admins: comma-separated player names to add to whitelist.json (optional).
--motd: custom MOTD message (optional). Default: "§cメンテナンス中 — 管理者のみ入場可".
--no-restart: Edit properties but do not start the server (handy when planning maintenance).
EOF
}

ADD_ADMINS=""
MOTD=${MOTD:-"§c現在サーバーメンテナンス中 — 管理者のみ入場可"}
NO_RESTART=false
for arg in "$@"; do
  case "$arg" in
    --add-admins)
      echo "--add-admins requires a comma-separated value. Use --add-admins=name1,name2" >&2
      usage; exit 1
      ;;
    --add-admins=*)
      ADD_ADMINS="${arg#*=}"
      ;;
    --motd)
      echo "--motd requires a value. Use --motd=\"message\"" >&2
      usage; exit 1
      ;;
    --motd=*)
      MOTD="${arg#*=}"
      ;;
    --no-restart)
      NO_RESTART=true
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      ;;
  esac
done

# Backup current configuration
TIMESTAMP=$(date +%Y%m%d%H%M%S)
cp server.properties "${BACKUP_DIR}/server.properties.pre-maintenance.${TIMESTAMP}.bak"
cp -f whitelist.json "${BACKUP_DIR}/whitelist.json.pre-maintenance.${TIMESTAMP}.bak" || true

# Set whitelist=true and update motd
if grep -q "^white-list=" server.properties 2>/dev/null; then
  sed -i 's/^white-list=.*/white-list=true/' server.properties
else
  echo "white-list=true" >> server.properties
fi
if grep -q "^motd=" server.properties 2>/dev/null; then
  sed -i "s/^motd=.*/motd=${MOTD//\//\\\//}/" server.properties
else
  echo "motd=${MOTD}" >> server.properties
fi

# Optionally add admins to whitelist.json based on --add-admins, or use existing ops.json entries
if [ -n "${ADD_ADMINS}" ]; then
  IFS=',' read -ra NAMES <<< "${ADD_ADMINS}"
  # existing whitelist.json content stored as jq manipulations if available
  if command -v jq >/dev/null 2>&1; then
    tmpfile=$(mktemp)
    if [ ! -f whitelist.json ]; then
      echo "[]" > whitelist.json
    fi
    cp whitelist.json ${tmpfile}
    for name in "${NAMES[@]}"; do
      # Attempt to add a minimal entry (name only) to the whitelist; UUID lookup not performed here
      if ! jq -e --arg n "${name}" '.[] | select(.name == $n)' ${tmpfile} >/dev/null 2>&1; then
        # try to lookup uuid from usercache.json
        uuid=""
        if [ -f usercache.json ]; then
          uuid=$(jq -r --arg n "${name}" '.[] | select(.name==$n) | .uuid // empty' usercache.json 2>/dev/null || true)
        fi
        if [ -n "${uuid}" ]; then
          jq --arg n "${name}" --arg u "${uuid}" '. + [{name:$n, uuid:$u}]' ${tmpfile} >${tmpfile}.new && mv ${tmpfile}.new ${tmpfile}
        else
          jq --arg n "${name}" '. + [{name:$n}]' ${tmpfile} >${tmpfile}.new && mv ${tmpfile}.new ${tmpfile}
        fi
      fi
    done
    mv ${tmpfile} whitelist.json
  else
    # fallback: use python3 to add names if available
    if command -v python3 >/dev/null 2>&1; then
      tmpfile=$(mktemp)
      # prepare python list of names in JSON
      NAMES_JSON=$(printf '%s\n' "${NAMES[@]}" | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
      python3 - <<PY > ${tmpfile}
import json,sys
names=${NAMES_JSON}
try:
    w=json.load(open('whitelist.json'))
except Exception:
    w=[]
try:
    cache=json.load(open('usercache.json'))
except Exception:
    cache=[]
cache_map={c['name']:c['uuid'] for c in cache if 'name' in c and 'uuid' in c}
for name in names:
    if not any((x.get('name')==name) for x in w):
        u=cache_map.get(name)
        entry={'name':name}
        if u:
            entry['uuid']=u
        w.append(entry)
json.dump(w,sys.stdout,ensure_ascii=False,indent=2)
PY
      mv ${tmpfile} whitelist.json
      echo "Added ${ADD_ADMINS} via python fallback" >&2
    else
      echo "jq not installed; skipping automatic whitelist additions. You can set --add-admins after installing jq." >&2
    fi
  fi
fi

# Ensure ops.json entries are present in whitelist.json (auto-merge ops -> whitelist)
merge_ops_into_whitelist() {
  if [ ! -f ops.json ]; then
    echo "ops.json not found; skipping ops -> whitelist merge" >&2
    return 0
  fi
  if [ ! -f whitelist.json ]; then
    echo "[]" > whitelist.json
  fi
  if [ ! -f usercache.json ]; then
    echo "usercache.json not found; lookups by uuid/name will be skipped" >&2
  fi
  if command -v jq >/dev/null 2>&1; then
    tmpfile=$(mktemp)
    # jq script builds a combined whitelist; if usercache.json exists, enrich ops with names
    if [ -f usercache.json ]; then
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
    echo "Merged ops.json into whitelist.json using jq" >&2
    local after_count
    after_count=$(json_length whitelist.json)
    echo "Whitelist size is now ${after_count}" >&2
  elif command -v python3 >/dev/null 2>&1; then
    tmpfile=$(mktemp)
    python3 - <<'PY' > ${tmpfile}
import json,sys
try:
    with open('whitelist.json','r') as f:
        w=json.load(f)
except Exception:
    w=[]
try:
    with open('ops.json','r') as f:
        o=json.load(f)
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
    echo "Merged ops.json into whitelist.json using python" >&2
    local after_count
    after_count=$(json_length whitelist.json)
    echo "Whitelist size is now ${after_count}" >&2
  else
    echo "Neither jq nor python3 found; cannot auto-merge ops.json into whitelist.json" >&2
  fi
}
json_length() {
  if command -v jq >/dev/null 2>&1; then
    jq -r 'length' "$1" 2>/dev/null || echo 0
  elif command -v python3 >/dev/null 2>&1; then
    python3 - <<PY 2>/dev/null
import json
print(len(json.load(open('$1'))))
PY
  else
    echo 0
  fi
}

before_count=$(json_length whitelist.json)
echo "Whitelist size before merge: ${before_count}" >&2
merge_ops_into_whitelist
after_count=$(json_length whitelist.json)
echo "Whitelist size after merge: ${after_count}" >&2

echo "Maintenance mode: whitelist enabled and MOTD updated. Backups written to ${BACKUP_DIR}" >&2

if [ "${NO_RESTART}" = true ]; then
  echo "No restart requested. Exiting." >&2
  exit 0
fi

echo "Starting server in maintenance mode..."

# Start RCON forwarder (if helper script exists). Starting it here ensures RCON
# access in maintenance mode even if start.sh isn't invoked, and mirrors start.sh behaviour.
if [ -x "scripts/start_rcon_forwarder.sh" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl --quiet is-active hs-rcon-forwarder.service >/dev/null 2>&1; then
      bash -lc "scripts/start_rcon_forwarder.sh" >/dev/null 2>&1 || true
    fi
  else
    bash -lc "scripts/start_rcon_forwarder.sh" >/dev/null 2>&1 || true
  fi
fi

exec bash "${REPO_ROOT}/start.sh"
