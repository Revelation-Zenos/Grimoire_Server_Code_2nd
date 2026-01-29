#!/usr/bin/env bash
cd "$(dirname "$0")"

# Prevent accidental double start of Minecraft server by checking for an existing process
FORCE_START=${FORCE_START:-false}
if [ "$FORCE_START" != "true" ]; then
	# Look for processes that mention 'minecraft_server.jar'. Multiple servers can coexist on one host, so
	# only abort if an existing Java process is using *this directory's* minecraft_server.jar.
	pids=$(pgrep -f "minecraft_server.jar" || true)
	found_blocking=""
	nonjava_pids=""
	for pid in $pids; do
		if [ -d "/proc/$pid" ]; then
			exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
			case "$exe" in
				*/java|*/javaw)
					# Inspect the process command line and try to find the '-jar <path>' argument.
					cmdline=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || true)
					jarArg=""
					# split cmdline by whitespace and search for '-jar'
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
							# Only treat as blocking if the running process was started from this working directory.
							proc_cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
							if [ "$proc_cwd" = "$PWD" ]; then
								found_blocking="$found_blocking $pid"
							else
								# Same jar file in use but in a different working dir (e.g., subserver). Ignore.
								:
							fi
						fi
					else
						# No '-jar' arg found; treat as non-standard matching process
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
else
	echo "FORCE_START=true: skipping double-start check" >&2
fi

# RCON configuration: if RCON_PASSWORD (and RCON_PORT optional) is provided, ensure server.properties is updated
RCON_PASSWORD_ENV=${RCON_PASSWORD:-}
RCON_PORT_ENV=${RCON_PORT:-25575}
RCON_BIND_ADDR_ENV=${RCON_BIND_ADDR:-}
if [ -n "${RCON_PASSWORD_ENV}" ]; then
	# Replace or append rcon.enabled
	if grep -q "^enable-rcon=" server.properties 2>/dev/null; then
		sed -i "s/^enable-rcon=.*/enable-rcon=true/" server.properties
	else
		echo "enable-rcon=true" >> server.properties
	fi
	# Replace or append rcon.port
	if grep -q "^rcon.port=" server.properties 2>/dev/null; then
		sed -i "s/^rcon.port=.*/rcon.port=${RCON_PORT_ENV}/" server.properties
	else
		echo "rcon.port=${RCON_PORT_ENV}" >> server.properties
	fi
	# Replace or append rcon.password
	if grep -q "^rcon.password=" server.properties 2>/dev/null; then
		sed -i "s/^rcon.password=.*/rcon.password=${RCON_PASSWORD_ENV//\//\\\//}/" server.properties
	else
		echo "rcon.password=${RCON_PASSWORD_ENV}" >> server.properties
	fi
	# Prefer explicit rcon.bind-address if provided via RCON_BIND_ADDR; otherwise, if server-ip is set, bind RCON to it to avoid 0.0.0.0 conflicts
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
	echo "RCON enabled in server.properties using environment variables (rcon.port=${RCON_PORT_ENV})."
fi

# JVM options: allow override by setting JAVA_OPTS env var when running start.sh
# By default, we enable native access and open necessary packages to avoid
# reflective/native-access warnings from libraries like JNA and JOML on newer JDKs.
JAVA_OPTS=${JAVA_OPTS:--Djava.net.preferIPv4Stack=true --enable-native-access=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.lang.invoke=ALL-UNNAMED --add-opens java.base/jdk.internal.misc=ALL-UNNAMED}

# Launch auto-backup after a delay to allow server startup (5 minutes)
# Uses nohup to detach the background job so it survives even when we exec java.
# You can override the delay with BACKUP_DELAY_SECONDS environment variable (default 300).
BACKUP_DELAY_SECONDS=${BACKUP_DELAY_SECONDS:-300}
if [ -x "scripts/auto_backup.sh" ]; then
		nohup bash -lc "sleep ${BACKUP_DELAY_SECONDS} && bash scripts/auto_backup.sh" >/dev/null 2>&1 &
fi

# Start RCON forwarder (if helper script exists). This allows exposing RCON on
# a separate IP (local bind) while the game server binds to server-ip.
if [ -x "scripts/start_rcon_forwarder.sh" ]; then
	# Prefer systemd-managed unit if it exists and is active (avoid duplicate forwarders)
	if command -v systemctl >/dev/null 2>&1; then
		if ! systemctl --quiet is-active hs-rcon-forwarder.service >/dev/null 2>&1; then
			bash -lc "scripts/start_rcon_forwarder.sh" >/dev/null 2>&1 || true
		fi
	else
		bash -lc "scripts/start_rcon_forwarder.sh" >/dev/null 2>&1 || true
	fi
fi

if [ ! -f minecraft_server.jar ]; then
	echo "minecraft_server.jar not found in $(pwd)." >&2
	if [ "${AUTO_FIX_JAR:-false}" = "true" ]; then
		# try to auto-detect a single server jar in the folder
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

echo "Launching Minecraft server..."
# Start the Minecraft server in background to capture the real Java PID (reliable for stop/health checks).
java ${JAVA_OPTS} -Xms6G -Xmx6G -jar minecraft_server.jar >> start_out.log 2>&1 &
java_pid=$!
# Write Java PID for consumers; keep wrapper PID in start_sh_pid.txt for compatibility
if ! { echo "${java_pid}" > start_pid.txt; } 2>/dev/null; then
	echo "Warning: cannot write start_pid.txt (permission denied). Continuing." >&2
fi
if ! { echo $$ > start_sh_pid.txt; } 2>/dev/null; then
	# non-fatal
	:
fi
# Wait for Java process to exit and capture its exit code
wait "${java_pid}"
rc=$?
echo "$(date '+%F %T') Minecraft server exited with code ${rc}" >> start_out.log
# clean up pidfiles on normal exit
rm -f start_sh_pid.txt || true
rm -f start_pid.txt || true
if [ ${rc} -ne 0 ]; then
	echo "Minecraft server process exited with code ${rc}; check start_out.log and logs/latest.log for details." >&2
	exit ${rc}
fi
exit 0
