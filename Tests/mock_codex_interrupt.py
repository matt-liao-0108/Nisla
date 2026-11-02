#!/usr/bin/env python3
"""Interrupt protocol fixture only: no accounts, models or user files."""
import json
import sys
import time

attempts = {}
turns = {}

def emit(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    row = json.loads(line)
    method, identifier = row.get("method"), row.get("id")
    params = row.get("params", {})
    thread = params.get("threadId")
    result = {}
    if method == "thread/list":
        result = {"data": []}
    elif method == "thread/resume":
        result = {"thread": {"id": thread}}
    elif method == "turn/start":
        turns[thread] = turns.get(thread, 0) + 1
        turn = f"{thread}-{turns[thread]}"
        # Deliberately omit turn/started: the client must use the RPC response.
        time.sleep(0.12)
        result = {"turn": {"id": turn, "status": "inProgress"}}
    elif method == "turn/interrupt":
        assert params["turnId"] == f"{thread}-{turns[thread]}", "Must target the exact live turn"
        attempts[thread] = attempts.get(thread, 0) + 1
        if thread == "retry" and attempts[thread] == 1:
            emit({"id": identifier, "error": {"code": -32000, "message": "fixture-interrupt-denied"}})
            continue
        assert attempts[thread] == (2 if thread == "retry" else turns[thread]), "Duplicate stop request"
    if identifier is not None:
        emit({"id": identifier, "result": result})
    if method == "turn/start":
        if turns[thread] > 1:
            emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": f"{thread}-{turns[thread]-1}", "status": "interrupted"}}})
        emit({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": turn, "delta": "Partial reply"}})
    elif method == "turn/interrupt":
        if thread == "unconfirmed":
            continue
        # An RPC acknowledgement must not prematurely mark the task stopped.
        time.sleep(0.2)
        emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": params["turnId"], "status": "interrupted"}}})
        emit({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": params["turnId"], "delta": "STALE"}})
