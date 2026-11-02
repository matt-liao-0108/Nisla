#!/usr/bin/env python3
"""Startup recovery fixture. Does not access real services, credentials or models."""
import json
import sys
import time

if "proxy" in sys.argv:
    if "unsupported" in sys.argv:
        sys.stderr.write("error: unrecognized subcommand 'proxy'\n")
    elif "permission" in sys.argv:
        sys.stderr.write("Error: Permission denied (os error 13)\n")
    else:
        sys.stderr.write("Error: failed to connect to socket at /Users/private-fixture/token-secret/control.sock\n")
        sys.stderr.flush()
        time.sleep(0.01)
        sys.stderr.write("Caused by: No such file or directory (os error 2)\n")
    sys.stderr.flush()
    raise SystemExit(1)

if "--stdio" in sys.argv:
    sys.stderr.write("error: unexpected argument '--stdio'\n")
    raise SystemExit(2)

for line in sys.stdin:
    row = json.loads(line)
    method = row.get("method")
    identifier = row.get("id")
    if identifier is None:
        continue
    result = {}
    if method == "initialize":
        result = {"userAgent": "recovery-fixture"}
    elif method == "thread/list":
        result = {"data": [{"id": "recovery-thread", "name": "Fixture", "updatedAt": 0}]}
    elif method == "account/rateLimits/read":
        result = {"rateLimits": {}}
    elif method == "thread/resume":
        result = {"thread": {"id": "recovery-thread"}}
    print(json.dumps({"id": identifier, "result": result}), flush=True)
