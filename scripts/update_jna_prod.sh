#!/usr/bin/env bash
# update_jna_prod.sh - Safely replace embedded JNA jars in minecraft_server.jar
# Usage:
#   bash scripts/update_jna_prod.sh [--dry-run] [--test-only] [--apply]
# Environment:
#   BACKUP_DIR    (default backups)
#   FORCE         (skip interactive prompts true/false)
set -euo pipefail

BACKUP_DIR=${BACKUP_DIR:-backups}
DRY_RUN=${DRY_RUN:-false}
TEST_ONLY=${TEST_ONLY:-false}
APPLY=${APPLY:-false}
JNA_VERSION=${JNA_VERSION:-5.18.1}
JNA_URL_BASE=${JNA_URL_BASE:-https://repo1.maven.org/maven2/net/java/dev/jna/jna}
JNA_PLATFORM_URL_BASE=${JNA_PLATFORM_URL_BASE:-https://repo1.maven.org/maven2/net/java/dev/jna/jna-platform}

info(){ echo "[update_jna] $*" >&2; }
err(){ echo "[update_jna] ERROR: $*" >&2; }

usage(){
  cat <<EOF
Usage: update_jna_prod.sh [--dry-run] [--test-only] [--apply]
  --dry-run    : create repacked jar but do not test or apply
  --test-only  : run test server with repacked jar but do not apply
  --apply      : apply to production (stop server, replace jar, restart)
Example: DRY_RUN=false bash scripts/update_jna_prod.sh --test-only
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    --test-only)
      TEST_ONLY=true
      ;;
    --apply)
      APPLY=true
      ;;
    -h|--help)
      usage; exit 0
      ;;
  esac
done

if [ "$DRY_RUN" = "true" ]; then
  info "DRY_RUN enabled: will not write to production"
fi

# ensure that backups are created in the repo root to avoid issues when
# running this script from a temporary working directory

if ! command -v jar >/dev/null 2>&1; then
  err "jar command not found. Install openjdk or the jar tool."
  exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
  err "sha256sum not found."
  exit 1
fi

if [ ! -f minecraft_server.jar ]; then
  err "minecraft_server.jar not found in $(pwd)"
  exit 1
fi

REPO_ROOT=$(pwd)
BACKUP_DIR_ABS="${REPO_ROOT}/${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR_ABS}"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
JAR_SHA=$(sha256sum minecraft_server.jar | awk '{print $1}')
info "Current jar SHA: ${JAR_SHA}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT
cd "${TMPDIR}"

info "Copying current jar into temp: ${TMPDIR}"
cp "${REPO_ROOT}/minecraft_server.jar" ./minecraft_server.jar

info "Unpacking jar..."
jar -xf minecraft_server.jar

download_and_replace(){
  local artifact_name=$1
  local base_url=$2
  local ver=$3
  local artifact=$(echo "${artifact_name}" | cut -d':' -f2)
  local filename="${artifact}-${ver}.jar"
  local url="${base_url}/${ver}/${filename}"
  info "Downloading ${filename} from ${url}"
  curl -fsSLo "/tmp/${filename}" "${url}"
  # artifact_name is group:artifact; convert group dots to slashes for path
  local group=$(echo "${artifact_name}" | cut -d':' -f1)
  local artifact=$(echo "${artifact_name}" | cut -d':' -f2)
  local grouppath=${group//./\/}
  local dest_dir="META-INF/libraries/${grouppath}/${artifact}/${ver}"
  mkdir -p "${dest_dir}"
  info "Replacing ${dest_dir}/${filename}"
  cp "/tmp/${filename}" "${dest_dir}/${filename}"
}

download_and_replace "net.java.dev.jna:jna" "${JNA_URL_BASE}" "${JNA_VERSION}"
download_and_replace "net.java.dev.jna:jna-platform" "${JNA_PLATFORM_URL_BASE}" "${JNA_VERSION}"

# Remove older jna versions if present (keep only desired JNA_VERSION)
for artifact in jna jna-platform; do
  base_dir="META-INF/libraries/net/java/dev/jna/${artifact}"
  if [ -d "${base_dir}" ]; then
    for vdir in "${base_dir}"/*; do
      if [ -d "${vdir}" ]; then
        vname=$(basename "$vdir")
        if [ "$vname" != "$JNA_VERSION" ]; then
          info "Removing old ${artifact} version: ${vname}"
          rm -rf "${vdir}"
        fi
      fi
    done
  fi
done

info "Recalculating META-INF/libraries.list"
python3 - <<'PY'
import os, hashlib
libs=[]
for root,dirs,files in os.walk('META-INF/libraries'):
  for f in files:
    if f.endswith('.jar'):
      path=os.path.join(root,f)
      rel=os.path.relpath(path,'META-INF/libraries')
      parts=rel.split('/')
      # expected structure: libraries/<group_path>/<artifact>/<version>/<jar>
      if len(parts)>=4:
        group='.'.join(parts[0:-3])
        artifact=parts[-3]
        version=parts[-2]
        gav='%s:%s:%s' % (group, artifact, version)
        with open(path,'rb') as fh:
          h=hashlib.sha256(fh.read()).hexdigest()
        libs.append((h,gav,rel))
libs.sort(key=lambda x:x[1])
with open('META-INF/libraries.list', 'w') as out:
  for h,gav,rel in libs:
    out.write(f"{h}\t{gav}\t{rel}\n")
print('Wrote META-INF/libraries.list with %d entries' % len(libs))
PY

info "Repacking jar..."
jar -cfm minecraft_server.jar META-INF/MANIFEST.MF .

REPACKED_SHA=$(sha256sum minecraft_server.jar | awk '{print $1}')
info "Repacked jar SHA: ${REPACKED_SHA}"

OUTFILE="${REPO_ROOT}/minecraft_server.jna-updated.${TIMESTAMP}.jar"
cp minecraft_server.jar "${OUTFILE}"
info "Wrote updated jar: ${OUTFILE}"

if [ "${DRY_RUN}" = "true" ]; then
  info "DRY_RUN mode: stopping here."
  exit 0
fi

if [ "${TEST_ONLY}" = "true" ]; then
  info "Starting test server with updated jar in temporary directory"
  mkdir -p "${TMPDIR}/testenv"
  cd "${TMPDIR}/testenv"
  cp "${OUTFILE}" ./minecraft_server.jar
  cp -r "${REPO_ROOT}/Hyouki PublicTestServer" ./testworld || true
  cp "${REPO_ROOT}/server.properties" ./server.properties || true
  echo "eula=true" > eula.txt
  JAVA_OPTS='--enable-native-access=ALL-UNNAMED'
  nohup bash -lc "java ${JAVA_OPTS} -Xms2G -Xmx2G -jar minecraft_server.jar nogui" > test.log 2>&1 &
  sleep 8
  tail -n 120 test.log || true
  info "Test server started in ${TMPDIR}/testenv; check test.log"
  exit 0
fi

if [ "${APPLY}" = "true" ]; then
  info "Applying to production: making backup of current jar and world"
  bakjar="${BACKUP_DIR_ABS}/minecraft_server.jar.${TIMESTAMP}.bak"
  bakworld="${BACKUP_DIR_ABS}/world-backup.${TIMESTAMP}.tar.gz"
  info "Backing up jar -> ${bakjar}"
  cp "${REPO_ROOT}/minecraft_server.jar" "${bakjar}"
  info "Backing up world -> ${bakworld}"
  tar -czf "${bakworld}" "${REPO_ROOT}/Hyouki PublicTestServer" "${REPO_ROOT}/world" || true

  info "Stopping existing server (attempt graceful stop)..."
  # attempt rcon stop; fallback to pkill
  if command -v mcrcon >/dev/null 2>&1 && [ -n "${RCON_PASSWORD:-}" ]; then
    mcrcon -p "${RCON_PASSWORD}" stop || true
    sleep 3
  fi
  if pgrep -f "minecraft_server.jar" >/dev/null; then
    info "Sending SIGTERM to java processes"
    pkill -f "minecraft_server.jar" || true
    sleep 6
  fi

  info "Replacing production jar with updated jar"
  mv "${REPO_ROOT}/minecraft_server.jar" "${REPO_ROOT}/minecraft_server.jar.bak.${TIMESTAMP}"
  cp "${OUTFILE}" "${REPO_ROOT}/minecraft_server.jar"
  info "Restarting server using start.sh"
  (cd "${REPO_ROOT}" && nohup bash start.sh > start_out.log 2>&1 &)
  info "Server restart requested. Check logs/latest.log and start_out.log for errors"
  exit 0
fi

info "If you want to run tests: set TEST_ONLY=true or to apply, set APPLY=true"
exit 0
