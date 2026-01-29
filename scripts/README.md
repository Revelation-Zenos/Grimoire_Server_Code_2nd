RCON Forwarder & systemd units
==============================

This folder contains helper scripts and systemd units for running an RCON
forwarder and persisting iptables rules so that the RCON service is only
exposed on a separate IP (192.168.11.16) while the game server binds to
server-ip (192.168.11.26).

Quick install (on the host):

  sudo bash scripts/install-systemd-units.sh

This will copy the units to /etc/systemd/system, reload systemd, enable and
start the following units:

- hs-rcon-forwarder.service — a systemd service to run the RCON forwarder
- hs-iptables.service      — a oneshot service to add the iptables rule to
                            drop direct RCON to the game server address

Notes
- If you don't use systemd, `start.sh` will call `scripts/start_rcon_forwarder.sh`
  to start the forwarder in the background when launching the server.
- For systemd-managed environments the forwarder will be handled by systemd
  (and `start.sh` will not spawn a duplicate forwarder).
- The iptables rule is applied by `hs-iptables.service` and is saved to
  `/etc/iptables/rules.v4` if `iptables-save` is available. Ensure your
  system and package set (iptables-persistent) persist these rules.

Security
- Ensure RCON password is secure and avoid exposing RCON to untrusted networks.
- Consider limiting access to the 192.168.11.16 forwarder interface via firewall.
