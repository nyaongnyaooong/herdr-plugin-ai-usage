#!/usr/bin/env python3
import json
import os
import socket
import sys

method = sys.argv[1]
params = json.loads(sys.argv[2])
path = os.environ.get("HERDR_SOCKET_PATH") or os.path.expanduser("~/.config/herdr/herdr.sock")
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(path)
request = {"id": "ai-usage", "method": method, "params": params}
sock.sendall((json.dumps(request) + "\n").encode())
chunks = []
while True:
    data = sock.recv(65536)
    if not data:
        break
    chunks.append(data)
    if b"\n" in data:
        break
sys.stdout.buffer.write(b"".join(chunks).split(b"\n", 1)[0])
