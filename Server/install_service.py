#!/usr/bin/env python3
"""Install/update this user's loopback launch agent, preserving its device registry."""
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

source = Path(__file__).parent
root = Path.home() / "Library/Application Support/TableLogServer"
app = root / "app"
app.mkdir(parents=True, exist_ok=True, mode=0o700)
root.chmod(0o700)
for name in ("server.py", "transcribe_worker.py"):
    shutil.copy2(source / name, app / name)
label = "com.yunju.tablelog-server"
agent = Path.home() / "Library/LaunchAgents" / (label + ".plist")
agent.parent.mkdir(parents=True, exist_ok=True)
agent.write_bytes(plistlib.dumps({"Label": label, "ProgramArguments": [sys.executable, str(app / "server.py"), "serve"],
    "RunAtLoad": True, "KeepAlive": True, "ProcessType": "Background", "Umask": 63,
    "EnvironmentVariables": {"TABLELOG_SERVER_HOME": str(root), "HF_HUB_OFFLINE": "1"},
    "StandardOutPath": str(root / "server.log"), "StandardErrorPath": str(root / "server.log")}))
domain = "gui/" + str(os.getuid())
subprocess.run(["launchctl", "bootout", domain + "/" + label], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["launchctl", "enable", domain + "/" + label], check=True)
subprocess.run(["launchctl", "bootstrap", domain, str(agent)], check=True)
print("Installed TableLog on 127.0.0.1:7870. Device records preserved.")
