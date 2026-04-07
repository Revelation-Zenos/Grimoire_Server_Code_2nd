#!/usr/bin/env python3
"""
Simple TCP forwarder: listen on local (bind_host:bind_port) and proxy to dest_host:dest_port
Usage:
  python3 rcon_forwarder.py bind_host bind_port dest_host dest_port

This script is intentionally small: use systemd or nohup to run it persistently.
"""
import sys
import socket
import threading
import select


def handle_client(client_sock, dest_addr):
    try:
        remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote.connect(dest_addr)
    except Exception as e:
        try:
            client_sock.close()
        except Exception:
            pass
        return

    sockets = [client_sock, remote]
    try:
        while True:
            rlist, _, _ = select.select(sockets, [], [])
            if client_sock in rlist:
                data = client_sock.recv(4096)
                if not data:
                    break
                remote.sendall(data)
            if remote in rlist:
                data = remote.recv(4096)
                if not data:
                    break
                client_sock.sendall(data)
    finally:
        try:
            client_sock.close()
        except Exception:
            pass
        try:
            remote.close()
        except Exception:
            pass


class ThreadedTCPServer:
    def __init__(self, bind_addr, bind_port, dest_addr, dest_port):
        self.bind_addr = bind_addr
        self.bind_port = int(bind_port)
        self.dest_addr = dest_addr
        self.dest_port = int(dest_port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((self.bind_addr, self.bind_port))
        self.sock.listen(64)

    def serve_forever(self):
        try:
            while True:
                client, addr = self.sock.accept()
                t = threading.Thread(target=handle_client, args=(client, (self.dest_addr, self.dest_port)))
                t.daemon = True
                t.start()
        finally:
            try:
                self.sock.close()
            except Exception:
                pass


if __name__ == '__main__':
    if len(sys.argv) != 5:
        print("Usage: rcon_forwarder.py bind_host bind_port dest_host dest_port", file=sys.stderr)
        sys.exit(1)
    bind_host, bind_port, dest_host, dest_port = sys.argv[1:]
    print(f"Starting forwarder {bind_host}:{bind_port} -> {dest_host}:{dest_port}")
    srv = ThreadedTCPServer(bind_host, bind_port, dest_host, dest_port)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
