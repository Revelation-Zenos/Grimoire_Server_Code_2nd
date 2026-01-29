#!/usr/bin/env bash
cd "$(dirname "$0")"
# Start subserver on port 10513 with IPv4 preference and 2G heap
JAVA_OPTS="-Djava.net.preferIPv4Stack=true ${JAVA_OPTS}"
nohup java ${JAVA_OPTS} -Xms2G -Xmx2G -jar ../minecraft_server.jar > start_out_10513.log 2>&1 &
echo $! > start_pid_10513.txt
sleep 1
ps -p $(cat start_pid_10513.txt) -o pid,cmd
