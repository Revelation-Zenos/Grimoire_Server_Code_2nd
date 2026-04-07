#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# Add a rule dropping direct RCON connections to the server IP (192.168.11.26:6430)
RCON_SERVER_IP=192.168.11.26
RCON_PORT=6430

ensure_rule() {
  sudo iptables -C INPUT -d ${RCON_SERVER_IP} -p tcp --dport ${RCON_PORT} -j DROP >/dev/null 2>&1 || \
    sudo iptables -A INPUT -d ${RCON_SERVER_IP} -p tcp --dport ${RCON_PORT} -j DROP
}

save_rules() {
  # Persist rules (requires iptables-persistent or compatible system)
  if command -v iptables-save >/dev/null 2>&1; then
    sudo mkdir -p /etc/iptables
    sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
  fi
}

ensure_rule
save_rules

echo "iptables rule ensured: drop ${RCON_SERVER_IP}:${RCON_PORT} and rules saved to /etc/iptables/rules.v4 (if possible)"
