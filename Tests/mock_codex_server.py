#!/usr/bin/env python3
"""Deterministic protocol fixture. No accounts, files, or models are accessed."""
import json
import sys

def send(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    row = json.loads(line)
    method = row.get("method")
    identifier = row.get("id")
    result = {}
    if method == "initialize":
        result = {"userAgent": "fixture"}
    elif method == "thread/list":
        result = {"data": [{"id": "fixture-thread", "name": "Fixture task", "updatedAt": 0}]}
    elif method == "account/rateLimits/read":
        result = {"rateLimits": {"primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 2000000000}}}
    elif method == "thread/resume":
        if row.get("params", {}).get("threadId") == "occupied-thread":
            send({"id": identifier, "error": {"code": -32000, "message": "thread occupied-thread already has an active writer"}})
            continue
        result = {"thread": {"id": "fixture-thread"}}
    elif method == "turn/start":
        result = {"turn": {"id": "fixture-turn"}}
    if method and identifier is not None:
        send({"id": identifier, "result": result})
    if method == "turn/start":
        send({"method": "turn/started", "params": {"threadId": "fixture-thread", "turn": {"id": "fixture-turn"}}})
        send({"method": "item/agentMessage/delta", "params": {"threadId": "fixture-thread", "delta": "Fixture reply"}})
        send({"id": "approval-1", "method": "item/commandExecution/requestApproval", "params": {"threadId": "fixture-thread", "command": "fixture-only"}})
    if method == "thread/resume" and row.get("params", {}).get("threadId") == "long-thread":
        send({"method": "item/agentMessage/delta", "params": {"threadId": "long-thread", "delta": "x" * 200000}})
        send({"method": "account/rateLimits/updated", "params": {"rateLimits": {"primary": {"usedPercent": -1e100}}}})
    if method is None and identifier == "approval-1":
        assert row["result"]["decision"] == "decline"
        send({"method": "serverRequest/resolved", "params": {"threadId": "fixture-thread", "requestId": "approval-1"}})
        send({"method": "turn/completed", "params": {"threadId": "fixture-thread"}})
