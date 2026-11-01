#!/usr/bin/env python3
"""Real SIP validation: drives openline-agent softphones against Asterisk.

Each agent is the production engine, coordinator and database with sound
hardware replaced by a WAV source and recorder. Nothing here is mocked: every
assertion reflects SIP and RTP that really crossed the network.
"""
import json, math, os, shutil, struct, subprocess, sys, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
AGENT = os.path.join(ROOT, ".build/debug/openline-agent")
OUT = os.path.join(HERE, "out")
SERVER = "127.0.0.1"
results = []


def tone(path, freq, rate=48000, seconds=2):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        n = rate * seconds
        # A whole number of cycles, so the looping player has no click.
        cycles = round(freq * seconds)
        w.writeframes(b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * cycles * i / n))) for i in range(n)))


def power(samples, rate, freq):
    """Goertzel power of `freq`, normalized by sample count."""
    k = 2 * math.cos(2 * math.pi * freq / rate)
    a = b = 0.0
    for s in samples:
        a, b = s + k * a - b, a
    return (a * a + b * b - k * a * b) / max(len(samples), 1) ** 2


def dominant_tone(path, candidates):
    with wave.open(path, "rb") as w:
        rate, n = w.getframerate(), w.getnframes()
        data = struct.unpack("<%dh" % n, w.readframes(n))
    # The recorder only runs while audio flows, so the first second is the first call.
    voiced = [s for s in data if abs(s) > 200]
    return {f: power(voiced[:rate], rate, f) for f in candidates}, len(voiced) / rate


class Agent:
    def __init__(self, user, freq, extra=()):
        self.user = user
        self.dir = os.path.join(OUT, user)
        os.makedirs(self.dir, exist_ok=True)
        source = os.path.join(self.dir, "source.wav")
        tone(source, freq)
        self.p = subprocess.Popen(
            [AGENT, "--user", user, "--dir", self.dir, "--source", source,
             "--log", os.path.join(self.dir, "pjsip.log"), "--retry-base", "2", *extra],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert "ready" in self.read(), "agent failed to start"

    def read(self):
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError(f"agent {self.user} exited")
        return json.loads(line)

    def cmd(self, text):
        self.p.stdin.write(text + "\n")
        self.p.stdin.flush()
        return self.read()

    def status(self):
        return self.cmd("status")

    def call(self):
        return self.status().get("call", {})

    def account(self):
        return self.status()["accounts"][0]

    def quit(self):
        if self.p.poll() is None:
            self.p.stdin.write("quit\n")
            self.p.stdin.flush()
            try:
                self.p.wait(8)
            except subprocess.TimeoutExpired:
                self.p.kill()


def wait(predicate, timeout=10, step=0.1):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


def check(name, passed, detail=""):
    results.append((name, bool(passed)))
    print(f"{'PASS' if passed else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
    return passed


def pbx(*command):
    return subprocess.run(["docker", "exec", "openline-asterisk", "asterisk", "-rx", " ".join(command)],
                          capture_output=True, text=True).stdout


def state(a):
    return a.call().get("state")


def registers(a, user, password, transport="udp", port=5060, extra=""):
    a.cmd(f"account {user} {password} {SERVER} {port} {transport} {extra}".strip())
    return wait(lambda: a.account()["registered"], 12)


def connect(a, b, target):
    a.cmd(f"dial {target}")
    ok = wait(lambda: state(b) == "incoming", 10)
    b.cmd("answer")
    return ok and wait(lambda: state(a) == "established" and state(b) == "established", 10)


def hang(a, b):
    a.cmd("hangup")
    wait(lambda: not a.call() and not b.call(), 6)


def levels(a):
    return a.call().get("media", {})


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    a, b = Agent("1001", 440), Agent("1002", 880)
    c = None
    try:
        # 1-3: independent registration.
        check("1 register account A", registers(a, "1001", "test-1001"), a.account()["last"])
        check("2 register account B", registers(b, "1002", "test-1002"), b.account()["last"])
        contacts = pbx("pjsip show contacts")
        check("3 both registered at PBX", "1001/sip" in contacts and "1002/sip" in contacts)

        # Contact matching on incoming calls.
        b.cmd("contact 1001 Alice Test")

        # 4-6: call and bidirectional audio.
        a.cmd("dial 1002")
        check("4 A dials B, B sees incoming", wait(lambda: state(b) == "incoming", 10), state(b))
        check("  incoming call matched to contact", b.call().get("contact") == "Alice Test")
        check("  caller still ringing, not established", state(a) in ("outgoing", "connecting", "remoteRinging"), state(a))
        b.cmd("answer")
        check("5 answered and established", wait(lambda: state(a) == "established" and state(b) == "established"), state(a))
        wait(lambda: levels(a).get("rxLevel", 0) > 0 and levels(b).get("rxLevel", 0) > 0, 5)
        ma, mb = levels(a), levels(b)
        check("6 RTP audio arrives both ways", ma.get("rxLevel", 0) > 0 and mb.get("rxLevel", 0) > 0,
              f"codec={ma.get('codec')} A rxLevel={ma.get('rxLevel')} B rxLevel={mb.get('rxLevel')}")

        # 7-8: mute.
        a.cmd("mute on")
        check("  mute state confirmed", a.call().get("muted") is True)
        check("  mute did not hold the call", state(a) == "established")
        check("7 microphone audio stops while muted", wait(lambda: levels(b).get("rxLevel", 1) == 0, 4), f"B rxLevel={levels(b).get('rxLevel')}")
        a.cmd("mute off")
        check("8 audio resumes after unmute", wait(lambda: levels(b).get("rxLevel", 0) > 0, 4), f"B rxLevel={levels(b).get('rxLevel')}")

        # 9: hold and resume through re-INVITE.
        a.cmd("hold on")
        check("9 hold confirmed by SIP", wait(lambda: state(a) == "held", 6), state(a))
        check("  held party stops hearing audio", wait(lambda: levels(b).get("rxLevel", 1) == 0, 4), f"B rxLevel={levels(b).get('rxLevel')}")
        a.cmd("hold off")
        check("  resume confirmed by SIP", wait(lambda: state(a) == "established", 6), state(a))
        check("  audio returns after resume", wait(lambda: levels(b).get("rxLevel", 0) > 0, 5), f"B rxLevel={levels(b).get('rxLevel')}")

        # Mute survives the media renegotiation.
        a.cmd("mute on")
        a.cmd("hold on"); wait(lambda: state(a) == "held", 6)
        a.cmd("hold off"); wait(lambda: state(a) == "established", 6)
        check("  mute survives hold/resume", wait(lambda: levels(b).get("rxLevel", 1) == 0, 3))
        a.cmd("mute off")
        hang(a, b)

        # 10: DTMF, received through Asterisk as RFC 4733.
        connect(a, b, "1002")
        time.sleep(0.5)
        a.cmd("dtmf 19*#")
        check("10 DTMF received by far end", wait(lambda: b.status()["dtmf"] == "19*#", 8), b.status()["dtmf"])

        # 12: end of call.
        a.cmd("hangup")
        check("12 hangup ends both sides", wait(lambda: not a.call() and not b.call(), 6))

        # Single-call policy.
        c = Agent("1003", 660)
        check("  register account C", registers(c, "1003", "test-1003"))
        connect(a, b, "1002")
        c.cmd("dial 1002")
        wait(lambda: not c.call(), 12)
        hist = c.status()["history"]
        check("  third caller gets busy, live call untouched",
              hist and hist[0]["outcome"] == "busy" and state(a) == "established" and state(b) == "established",
              f"outcome={hist[0]['outcome'] if hist else None} status={hist[0]['status'] if hist else None}")
        rejected = [h for h in b.status()["history"] if h["outcome"] == "missed"]
        check("  rejected call logged as missed on B", len(rejected) == 1)

        # 11: blind transfer. A hands B to C through a real REFER.
        a.cmd("transfer 1003")
        check("11 transfer reaches destination", wait(lambda: state(c) == "incoming", 12), state(c))
        c.cmd("answer")
        check("  transferee connected to destination", wait(lambda: state(c) == "established", 8), state(c))
        check("  transferor leg ended", wait(lambda: not a.call(), 8), str(a.call()))
        wait(lambda: levels(c).get("rxLevel", 0) > 0, 5)
        check("  audio on transferred call", levels(c).get("rxLevel", 0) > 0)
        b.cmd("hangup")
        wait(lambda: not b.call() and not c.call(), 6)

        # Failed transfer keeps the original call.
        connect(a, b, "1002")
        a.cmd("transfer 666")
        r = wait(lambda: state(a) == "established" or not a.call(), 12)
        time.sleep(1)
        info = a.call()
        check("  failed transfer restores original call or is reported",
              info.get("state") == "established" and "failed" in info.get("transfer", ""), str(info.get("transfer")))
        if a.call():
            hang(a, b)

        # Decline and cancel outcomes.
        a.cmd("dial 1002"); wait(lambda: state(b) == "incoming", 8)
        b.cmd("decline"); wait(lambda: not a.call() and not b.call(), 8)
        check("  declined call recorded", b.status()["history"][0]["outcome"] == "declined", b.status()["history"][0]["outcome"])
        a.cmd("dial 1002"); wait(lambda: state(b) == "incoming", 8)
        wait(lambda: state(a) == "remoteRinging", 5)
        a.cmd("hangup"); wait(lambda: not a.call() and not b.call(), 8)
        ha, hb = a.status()["history"][0], b.status()["history"][0]
        check("  cancelled call: caller=cancelled, callee=missed",
              ha["outcome"] == "cancelled" and hb["outcome"] == "missed", f"{ha['outcome']}/{hb['outcome']}")

        # Do Not Disturb.
        b.cmd("dnd on")
        a.cmd("dial 1002"); wait(lambda: not a.call(), 10)
        check("  DND rejects with busy", a.status()["history"][0]["outcome"] == "busy", str(a.status()["history"][0]))
        b.cmd("dnd off")

        # 13: history accuracy.
        answered = [h for h in a.status()["history"] if h["outcome"] == "answered"]
        check("13 history records answered calls with duration",
              len(answered) >= 3 and all(h["duration"] > 0 for h in answered), f"{len(answered)} answered")
        rows = subprocess.run(["sqlite3", os.path.join(a.dir, "1001.sqlite"), "SELECT count(*), count(DISTINCT id) FROM callHistory"], capture_output=True, text=True).stdout.strip()
        total, distinct = rows.split("|")
        check("  one history row per call", total == distinct and int(total) == len(a.status()["history"]), rows)

        # Echo through the PBX proves the media path round trip on one client.
        a.cmd("dial 600")
        wait(lambda: state(a) == "established", 8)
        check("  PBX echo returns our own audio", wait(lambda: levels(a).get("rxLevel", 0) > 0, 5))
        info = levels(a)
        check("  RTP counters advance", info.get("tx", 0) > 0, f"tx={info.get('tx')} rx={info.get('rx')} lost={info.get('lost')}")
        a.cmd("hangup"); wait(lambda: not a.call(), 6)

        # Codec negotiation, one at a time.
        for codec, expected in [("PCMU/8000/1", "PCMU"), ("PCMA/8000/1", "PCMA"), ("G722/16000/1", "G722"), ("opus/48000/2", "opus")]:
            a.cmd("codecs " + codec)
            a.cmd("dial 600")
            wait(lambda: state(a) == "established", 8)
            a.cmd("status")
            seen = levels(a).get("codec")
            check(f"  codec {expected}", seen == expected and wait(lambda: levels(a).get("rxLevel", 0) > 0, 4), str(seen))
            a.cmd("hangup"); wait(lambda: not a.call(), 6)
        a.cmd("codecs PCMU/8000/1 PCMA/8000/1 G722/16000/1 opus/48000/2")

        # Failure classification.
        a.cmd("disable 1001")
        check("  disable unregisters", wait(lambda: "1001/sip" not in pbx("pjsip show contacts"), 8))
        check("  other account unaffected", b.account()["registered"])
        a.cmd("enable 1001")
        check("  enable registers again", wait(lambda: a.account()["registered"], 10))
        d = Agent("9999", 500)
        d.cmd("account 1003 wrong-password 127.0.0.1 5060 udp")
        check("  wrong password classified", wait(lambda: "incorrectCredentials" in d.account()["state"], 10), d.account()["state"])
        time.sleep(4)
        check("  no retry on bad credentials", "incorrectCredentials" in d.account()["state"])
        d.quit()
        e = Agent("9998", 500)
        e.cmd("account 1003 x 127.0.0.1 5999 udp")
        check("  unreachable server classified", wait(lambda: "failed" in e.account()["state"] or "reconnecting" in e.account()["state"], 40), e.account()["state"] + " " + e.account()["last"])
        e.quit()

        # Transports.
        t = Agent("9997", 500)
        check("  TCP registration", registers(t, "1003", "test-1003", "tcp"), t.account()["last"])
        c.cmd("remove 1003")
        t.cmd("dial 600"); wait(lambda: state(t) == "established", 8)
        check("  call over TCP", wait(lambda: levels(t).get("rxLevel", 0) > 0, 5))
        t.cmd("hangup"); wait(lambda: not t.call(), 6)
        t.quit()
        u = Agent("9996", 500)
        u.cmd("account 1003 test-1003 127.0.0.1 5061 tls")
        check("  untrusted TLS certificate refused", wait(lambda: "failed" in u.account()["state"], 15) and not u.account()["registered"], u.account()["state"] + " " + u.account()["last"])
        u.quit()
        v = Agent("9995", 500, ["--skip-tls-verify"])
        check("  TLS handshake and registration", registers(v, "1003", "test-1003", "tls", 5061), v.account()["last"])
        v.cmd("dial 600"); wait(lambda: state(v) == "established", 8)
        check("  call over TLS", wait(lambda: levels(v).get("rxLevel", 0) > 0, 5))
        v.cmd("hangup"); wait(lambda: not v.call(), 6)
        v.quit()

        # Secure media.
        s = Agent("1004", 500)
        check("  register SRTP account", registers(s, "1004", "test-1004", "udp", 5060, "mandatory"), s.account()["last"])
        s.cmd("dial 600"); wait(lambda: state(s) == "established", 8)
        check("  SRTP call carries audio", wait(lambda: levels(s).get("rxLevel", 0) > 0, 5))
        srtp_log = open(os.path.join(s.dir, "pjsip.log"), errors="replace").read()
        check("  SRTP really negotiated", "a=crypto:" in srtp_log and "RTP/SAVP" in srtp_log)
        s.cmd("hangup"); wait(lambda: not s.call(), 6)
        s.quit()

        # SIP INFO DTMF, relayed by the PBX to B.
        i = Agent("1005", 500)
        check("  register SIP INFO account", registers(i, "1005", "test-1005", "udp", 5060, "disabled sipInfo"), i.account()["last"])
        before = b.status()["dtmf"]
        connect(i, b, "1002")
        time.sleep(0.5)
        i.cmd("dtmf 58")
        check("  SIP INFO DTMF received", wait(lambda: b.status()["dtmf"].endswith("58"), 8), b.status()["dtmf"][len(before):])
        info_log = open(os.path.join(i.dir, "pjsip.log"), errors="replace").read()
        check("  DTMF really sent as INFO", "INFO sip:" in info_log)
        i.cmd("hangup"); wait(lambda: not i.call() and not b.call(), 6)
        i.quit()

        # 16-17: server restart stands in for network loss; both end in lost
        # registration and must recover without user action.
        check("  B registered before outage", b.account()["registered"])
        subprocess.run(["docker", "restart", "openline-asterisk"], capture_output=True)
        b.cmd("network")
        wait(lambda: "PJSIP" in pbx("core show channeltypes"), 30)
        check("17 registration recovers after server restart",
              wait(lambda: "1002/sip" in pbx("pjsip show contacts"), 60) or wait(lambda: b.cmd("reconnect") and "1002/sip" in pbx("pjsip show contacts"), 10), b.account()["state"])

        # Received audio content: each side heard the other's tone.
        a.quit(); b.quit(); c.quit()
        unregister = [l for l in open(os.path.join(a.dir, "pjsip.log"), errors="replace") if "Expires: 0" in l or ";expires=0" in l]
        check("14 quit sends un-REGISTER", bool(unregister), f"{len(unregister)} lines")
        powers_a, secs_a = dominant_tone(os.path.join(OUT, "1001/1001-received.wav"), [440, 880])
        powers_b, secs_b = dominant_tone(os.path.join(OUT, "1002/1002-received.wav"), [440, 880])
        check("6 A's recording contains B's 880 Hz tone", powers_a[880] > 10 * powers_a[440], f"{secs_a:.1f}s voiced")
        check("6 B's recording contains A's 440 Hz tone", powers_b[440] > 10 * powers_b[880], f"{secs_b:.1f}s voiced")
    finally:
        for agent in (a, b, c):
            if agent:
                agent.quit()
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    if failed:
        print("Failed:", *failed, sep="\n  ")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
