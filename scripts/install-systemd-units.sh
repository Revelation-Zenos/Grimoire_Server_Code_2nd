#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ "$EUID" -ne 0 ]; then
  echo "This installer must be run as root: sudo ./scripts/install-systemd-units.sh"
  exit 1
fi

echo "Installing systemd units for hs-rcon-forwarder and hs-iptables..."
install_unit() {
  local src="$1"
  local dst="/etc/systemd/system/$(basename "$src")"
  cp "$src" "$dst"
  chmod 644 "$dst"
  echo "Copied $src -> $dst"
}

install_unit "$REPO_ROOT/scripts/systemd/hs-rcon-forwarder.service"
install_unit "$REPO_ROOT/scripts/systemd/hs-iptables.service"

systemctl daemon-reload
systemctl enable hs-rcon-forwarder.service --now || true
systemctl enable hs-iptables.service --now || true

echo "Installed and enabled systemd units. Verify logs with: systemctl status hs-rcon-forwarder.service hs-iptables.service"
