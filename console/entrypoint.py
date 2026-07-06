#!/usr/bin/env python3
"""Open Design Console — entrypoint that runs Flask + ttyd side by side."""
import subprocess
import os
import signal
import sys

TUI_PASSWORD = os.environ.get("TUI_PASSWORD", "changeme")

def main():
    # ttyd: web terminal that kubectl-execs into open-design pod
    ttyd_cmd = [
        "ttyd", "-p", "7681",
        "-c", f"admin:{TUI_PASSWORD}",
        "-W",
        "/app/connect.sh",
    ]
    ttyd_proc = subprocess.Popen(ttyd_cmd)
    print(f"[entrypoint] ttyd started on :7681 (PID {ttyd_proc.pid})")

    # Flask: management dashboard
    flask_proc = subprocess.Popen(
        [sys.executable, "/app/app.py"],
        cwd="/app",
    )
    print(f"[entrypoint] Flask started on :18790 (PID {flask_proc.pid})")

    def shutdown(sig, frame):
        print(f"\n[entrypoint] Received signal {sig}, shutting down...")
        ttyd_proc.terminate()
        flask_proc.terminate()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Wait for either to exit
    pid, status = os.waitpid(-1, 0)
    print(f"[entrypoint] Process {pid} exited with {status}, shutting down...")
    ttyd_proc.terminate()
    flask_proc.terminate()
    sys.exit(1)

if __name__ == "__main__":
    main()
