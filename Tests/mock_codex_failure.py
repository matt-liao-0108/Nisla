#!/usr/bin/env python3
"""A rejected handshake that keeps its process alive unless the client cleans up."""
import json
import sys
import time

row = json.loads(sys.stdin.readline())
print(json.dumps({"id": row["id"], "error": {"code": -32000, "message": "fixture-handshake-denied"}}), flush=True)
while True:
    print("fixture remains alive", file=sys.stderr, flush=True)
    time.sleep(0.05)
