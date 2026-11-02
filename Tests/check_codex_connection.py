"""Read-only initialize handshake; never starts a thread or model turn."""
import json
import selectors
import subprocess
import sys

cli = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
process = subprocess.Popen([cli, "app-server", "--stdio" if "--direct" in sys.argv else "proxy"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    process.stdin.write(json.dumps({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "island", "title": "Island", "version": "0.2.0"}}}) + "\n")
    process.stdin.flush()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    events = selector.select(timeout=10)
    if events:
        line = process.stdout.readline()
        if line:
            row = json.loads(line)
            print("Handshake response:", "success" if "result" in row else "protocol error")
            if "error" in row:
                print("Error code:", row["error"].get("code"))
        else:
            print("No running Codex control service available; proxy closed its output.")
            error = process.stderr.read()
            if "Operation not permitted" in error or "Permission denied" in error:
                print("Reason: sandbox permission restriction")
            elif "No such file" in error:
                print("Reason: control socket not present")
            elif "Connection refused" in error:
                print("Reason: control socket refused connection")
    else:
        print("Codex control service handshake timed out.")
finally:
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
