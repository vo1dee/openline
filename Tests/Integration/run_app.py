#!/usr/bin/env python3
"""The real .app, driven by XCUITest, receives a real SIP call with its main
window closed. Asterisk and an openline-agent play the rest of the network."""
import os, shutil, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run

ROOT = run.ROOT
MARKER = "/tmp/openline-ui-rig"
open(MARKER, "w").close()
# Docker's NAT stops unregistration matching, so a previous run's contact would
# pass for this app's registration. Start from an empty PBX.
subprocess.run(["docker", "restart", "openline-asterisk"], capture_output=True)
run.wait(lambda: "PJSIP" in run.pbx("core show channeltypes"), 30, 1)
time.sleep(2)
shutil.rmtree(run.OUT, ignore_errors=True)
os.makedirs(run.OUT)
caller = run.Agent("1002", 880)
ok = run.registers(caller, "1002", "test-1002")
print("caller registered:", ok, flush=True)
test = subprocess.Popen(["xcodebuild", "-project", "Openline.xcodeproj", "-scheme", "Openline", "-derivedDataPath", "build/DerivedData",
                         "-destination", "platform=macOS,arch=arm64", "test", "-only-testing:OpenlineUITests/SmokeUITests"],
                       cwd=ROOT, stdout=open(os.path.join(run.OUT, "uitest.log"), "w"), stderr=subprocess.STDOUT)
try:
    run.wait(lambda: test.poll() is not None or "1006/sip" in run.pbx("pjsip show contacts"), 240, 1)
    print("app registered at PBX:", "1006/sip" in run.pbx("pjsip show contacts"), flush=True)
    time.sleep(6)  # The test closes the window here.
    # Docker Desktop's UDP proxy can rebind the client's port, and an INVITE sent
    # before the app re-registers then dies at the old mapping. Redial until the
    # test, which ends only once the panel appeared, has finished.
    for attempt in range(8):
        if test.poll() is not None:
            break
        caller.cmd("dial 1006")
        run.wait(lambda: not caller.call() or test.poll() is not None, 15)
        print("attempt", attempt + 1, caller.status()["history"][:1], flush=True)
        run.wait(lambda: test.poll() is not None, 6)
    print("caller history:", caller.status()["history"][:1], flush=True)
    test.wait(180)
finally:
    os.remove(MARKER)
    caller.quit()
print("xcodebuild exit:", test.returncode)
sys.exit(test.returncode)
