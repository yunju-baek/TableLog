#!/usr/bin/env python3
"""Exercise process-death recovery on an emulator with synthetic/silent microphone input.

Install the debug APK first. Requires adb in PATH. Refuses physical devices.
No production data is deleted; the test creates one clearly named recording.
"""
import argparse
import json
import re
import struct
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--serial", default="emulator-5554")
parser.add_argument("--output", default="verification-local/recovery.json")
args = parser.parse_args()
PACKAGE = "work.yunju.tablelog"


def adb(*command, binary=False):
    result = subprocess.check_output(["adb", "-s", args.serial, *command], timeout=30)
    return result if binary else result.decode("utf-8").strip()


def wait_for(check, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.25)
    raise AssertionError("Timed out waiting for emulator state")


def tap(text):
    adb("shell", "uiautomator", "dump", "/sdcard/tablelog-test-ui.xml")
    root = ET.fromstring(adb("shell", "cat", "/sdcard/tablelog-test-ui.xml"))
    node = next(n for n in root.iter("node") if n.get("text") == text or n.get("content-desc") == text)
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))


def records():
    files = adb("shell", "run-as", PACKAGE, "ls", "files/meetings").splitlines()
    return [json.loads(adb("shell", "run-as", PACKAGE, "cat", f"files/meetings/{id}/meeting.json")) for id in files]


assert adb("shell", "getprop", "ro.kernel.qemu") == "1", "Only an emulator may run this test"
adb("shell", "pm", "grant", PACKAGE, "android.permission.RECORD_AUDIO")
adb("shell", "pm", "grant", PACKAGE, "android.permission.POST_NOTIFICATIONS")
adb("shell", "am", "force-stop", PACKAGE)
adb("shell", "am", "start", "-n", f"{PACKAGE}/.MainActivity")
time.sleep(1)
tap("새 회의 녹음")
tap("녹음 시작")
meeting = wait_for(lambda: next((m for m in records() if m["status"] == "recording"), None))
meeting_id = meeting["id"]
print("Started synthetic recording", flush=True)
adb("shell", "input", "keyevent", "KEYCODE_HOME")
wait_for(lambda: next(m for m in records() if m["id"] == meeting_id)["durationSeconds"] >= 5)
before = next(m for m in records() if m["id"] == meeting_id)
adb("shell", "am", "force-stop", PACKAGE)
data = adb("exec-out", "run-as", PACKAGE, "cat", f"files/meetings/{meeting_id}/recording.wav", binary=True)
adb("shell", "am", "start", "-n", f"{PACKAGE}/.MainActivity")
recovered = wait_for(lambda: next((m for m in records() if m["id"] == meeting_id and m["status"] == "interrupted"), None))
repaired = adb("exec-out", "run-as", PACKAGE, "cat", f"files/meetings/{meeting_id}/recording.wav", binary=True)
assert data[44:] == repaired[44:], "Recovery changed PCM audio"
assert struct.unpack_from("<I", repaired, 40)[0] == len(repaired) - 44
assert recovered["durationSeconds"] == (len(repaired) - 44) / 32000
assert recovered["durationSeconds"] >= before["durationSeconds"] >= 5
report = {
    "emulator": args.serial, "background_recording": True, "process_death_recovery": True,
    "pcm_unchanged": True, "wav_header_matches_file": True,
    "duration_before_kill_seconds": before["durationSeconds"],
    "recovered_duration_seconds": recovered["durationSeconds"],
    "note": "Emulated silent input; no physical microphone or ASR quality assessment.",
}
path = Path(args.output)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False, indent=2))
