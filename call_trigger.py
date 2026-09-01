#!/usr/bin/env python3
"""Alert webhook: turns an HTTP request into an outbound Asterisk call.

Two producers feed this service:

  POST /          Uptime Kuma's notification webhook (its own JSON shape).
  POST /ha        Home Assistant, replacing the older ssh+shell_command path.

Both routes pre-synthesise the message to a wav BEFORE the call is placed —
the callee hears speech the moment they answer (no network wait after
"hello"), identical texts hit a content-hash cache, and free text never
enters the call file or a shell: it is sanitised at the single synth()
choke point and travels on only as a hash-named wav path.

The service runs as the `asterisk` user so spool files are owned correctly the
moment they appear — Asterisk needs to utime() them to schedule retries, and it
can only do that on files it owns. Running as root is what used to break that.
"""

import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PBX_ALERT_PORT", "5000"))
SECRET = os.environ.get("PBX_ALERT_SECRET", "")
SPOOL = os.environ.get("PBX_ALERT_SPOOL", "/var/spool/asterisk/outgoing")
# Same TTS helper the AGI relay uses (installed by install.sh); the env
# override exists for tests, not for production.
TTS_SCRIPT = os.environ.get("PBX_ALERT_TTS", "/var/lib/asterisk/agi-bin/edge_say.sh")

# Caller ID used when a request does not name one. Operator-set in
# /etc/pbx-alert.env (e.g. PBX_ALERT_CALLERID=<0501234567>). Many ITSPs accept
# several configured identities, so producers may pick a different one per call.
# If the operator sets none, the HA leg omits the CallerID directive entirely so
# the trunk dials with its own configured identity, instead of a placeholder like
# 0000000000 that many ITSPs reject.
ENV_CALLER_ID = os.environ.get("PBX_ALERT_CALLERID", "").strip()
DEFAULT_CALLER_ID = ENV_CALLER_ID or "<0000000000>"
KUMA_CHANNEL = "Local/999@from-ha-alerts"
AUDIO_MAX_AGE = 6 * 3600

# NOT /tmp. asterisk.service ships with PrivateTmp=true, so Asterisk sees a
# private /tmp namespace; a wav this service writes to the real /tmp is
# invisible to Playback, which fails and drops the call the instant the callee
# answers (the symptom is "app_playback.c: Playback failed" while the file
# plainly exists). This directory is shared, asterisk-owned, and survives a
# service restart (a private /tmp does not).
ALERT_DIR = os.environ.get("PBX_ALERT_AUDIO_DIR", "/var/lib/asterisk/alert-audio")


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def clean_caller_id(raw):
    """Validate a caller ID supplied by a producer.

    The value is written verbatim into a call file, where each line is a
    directive — so a newline in this field would let a caller append arbitrary
    directives of their own. Anything else the ITSP accepts is left alone.
    """
    if raw is None or str(raw).strip() == "":
        return ""
    value = str(raw).strip()
    if len(value) > 128:
        raise ValueError("caller_id too long")
    if any(ch in value for ch in "\r\n") or any(ord(ch) < 32 for ch in value):
        raise ValueError("caller_id contains control characters")
    # A bare number is what producers tend to send, but Asterisk reads an
    # unbracketed value as the display *name* and presents no number at all.
    if value.replace("+", "").isdigit():
        return f'<{value}>'
    return value


def clean_text(raw):
    """Reduce producer text to something safe to speak.

    Alert text is rendered by HA automations from outside content (calendar
    event names, device names), so treat it as untrusted. Allowlist, not
    blocklist: unicode word chars (Hebrew included), digits, whitespace, basic
    punctuation, plus the Hebrew geresh/gershayim used in acronyms. Everything
    else — quotes, $(), backticks, newlines — is dropped before the text can
    reach any other layer.
    """
    text = re.sub(r"\s+", " ", str(raw)).strip()
    text = re.sub(r"[^\w \.,!\?:;%'׳״-]", "", text)[:300].strip()
    if not text:
        raise ValueError("text is empty after sanitising")
    return text


def place_call(lines):
    """Write a call file into the spool directory.

    Built under a dotted name inside the spool itself and then renamed: a
    rename within one directory is atomic, so Asterisk's scanner never sees a
    half-written file. Writing to /tmp first would only be atomic while /tmp
    happens to share a filesystem with the spool.
    """
    name = uuid.uuid4().hex
    tmp = os.path.join(SPOOL, f".{name}.tmp")
    final = os.path.join(SPOOL, f"call_{name}.call")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.rename(tmp, final)
    return final


def synth(text):
    """Sanitise text and render it to /tmp/alert_<hash>.wav; return the base.

    Content-hash naming gives a cache: the same alert sent to three numbers is
    synthesised once. A cache hit refreshes mtime so sweep_old_audio() cannot
    reap a wav between queueing and a retried call. edge_say.sh writes the wav
    atomically (tmp + mv), so concurrent identical requests cannot corrupt it.
    """
    text = clean_text(text)
    os.makedirs(ALERT_DIR, exist_ok=True)
    base = os.path.join(ALERT_DIR,
                        f"alert_{hashlib.md5(text.encode('utf-8')).hexdigest()[:16]}")
    wav = f"{base}.wav"
    if os.path.exists(wav):
        os.utime(wav, None)
        return base
    subprocess.run(["/bin/bash", TTS_SCRIPT, text, base], check=True, timeout=20)
    if not os.path.exists(wav):
        raise RuntimeError(f"TTS produced no file for {base}")
    return base


def sweep_old_audio():
    """Drop TTS output the calls have long since finished with."""
    cutoff = time.time() - AUDIO_MAX_AGE
    if not os.path.isdir(ALERT_DIR):
        return
    for entry in os.scandir(ALERT_DIR):
        if not entry.name.startswith("alert_") or not entry.name.endswith(".wav"):
            continue
        try:
            if entry.stat().st_mtime < cutoff:
                os.unlink(entry.path)
        except OSError:
            pass  # owned by someone else, or already gone


def kuma_message(data):
    """Phrase an Uptime Kuma heartbeat as the sentence the caller will hear."""
    name = "שירות לא ידוע"
    if isinstance(data.get("monitor"), dict) and data["monitor"].get("name"):
        name = data["monitor"]["name"]
    elif data.get("msg"):
        name = data["msg"]

    beat = data.get("heartbeat")
    if isinstance(beat, dict) and "status" in beat:
        if beat["status"] == 0:
            return f"התראה דחופה! השירות {name} נפל. נא לבדוק."
        if beat["status"] == 1:
            return f"עדכון. השירות {name} חזר לפעולה תקינה."
        return f"התקבל דיווח לא מוכר על השירות {name}."
    return f"התקבל דיווח על השירות {name}."


def speak(text):
    """Kuma / manual-test leg: synthesise, then ring the hardcoded channel."""
    base = synth(text)
    place_call([
        f"Channel: {KUMA_CHANNEL}",
        f"CallerID: {DEFAULT_CALLER_ID}",
        "MaxRetries: 2",
        "RetryTime: 60",
        "WaitTime: 30",
        "Application: Playback",
        f"Data: {base},d",
    ])
    log(f"queued kuma call: {text[:60]}")


def ha_alert(payload):
    """HA leg: ring a specific number through a named trunk, speak the text."""
    # Field names match what the Home Assistant automations already send to
    # the retired shell_command, so switching them over is a one-line edit.
    def field(*names):
        for name in names:
            if payload.get(name) not in (None, ""):
                return str(payload[name]).strip()
        return ""

    phone = field("phone")
    trunk = field("trunk_name", "trunk")
    # sanitise up front so validation errors and log lines only ever carry the
    # cleaned text; synth() cleans again (idempotent) as defence in depth.
    text = clean_text(field("alert_data", "text"))
    # A request may name a caller ID; otherwise fall back to the operator's env
    # default. If neither is set, caller_id stays empty and the CallerID directive
    # is omitted, so the trunk dials with its own identity instead of a placeholder
    # the ITSP would reject.
    caller_id = clean_caller_id(payload.get("caller_id")) or clean_caller_id(
        ENV_CALLER_ID
    )
    if not phone.isdigit():
        raise ValueError(f"phone must be digits, got {phone!r}")
    if not trunk.replace("_", "").isalnum():
        raise ValueError(f"suspicious trunk {trunk!r}")

    # Synthesise BEFORE placing the call: instant speech on answer, and the
    # call file carries only a hash-named wav path — never producer text.
    base = synth(text)
    lines = [f"Channel: Local/{phone}@ha-outbound"]
    if caller_id:
        lines.append(f"CallerID: {caller_id}")
    lines += [
        "MaxRetries: 2",
        "RetryTime: 60",
        "WaitTime: 30",
        "Context: tts-alerts",
        "Extension: s",
        "Priority: 1",
        f"Set: ALERT_FILE={base}",
        f"Set: HA_TRUNK={trunk}",
    ]
    place_call(lines)
    log(f"queued ha call to {phone} via {trunk} "
        f"as {caller_id or '(trunk default)'}: {text[:40]}")


class Handler(BaseHTTPRequestHandler):
    server_version = "pbx-alert"

    def log_message(self, fmt, *args):
        pass  # the handlers below log what actually matters

    def _authorised(self):
        """Accept the secret from a header, or from the query string.

        The query form is what Uptime Kuma is already configured with and is
        kept working; the header form keeps it out of URLs and access logs and
        is what new producers should use.
        """
        supplied = self.headers.get("X-Alert-Secret", "")
        if not supplied:
            query = urllib.parse.urlparse(self.path).query
            supplied = urllib.parse.parse_qs(query).get("secret", [""])[0]
        return SECRET and hmac.compare_digest(supplied, SECRET)

    def _reply(self, code, body):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def _route(self):
        """Normalised path. Every route is matched explicitly: a typo in a
        producer's URL must return 404, never fall through to placing a call.
        """
        return urllib.parse.urlparse(self.path).path.rstrip("/") or "/"

    def do_GET(self):
        if not self._authorised():
            return self._reply(403, "forbidden")
        route = self._route()
        if route == "/health":
            return self._reply(200, "ok")
        if route != "/test":
            return self._reply(404, "no such route")
        try:
            speak("בדיקה ידנית. המערכת תקינה.")
            self._reply(200, "ok")
        except Exception as err:
            log(f"GET failed: {err}")
            self._reply(500, "error")

    def do_POST(self):
        if not self._authorised():
            return self._reply(403, "forbidden")
        route = self._route()
        if route == "/health":
            return self._reply(200, "ok")
        if route not in ("/", "/kuma", "/ha"):
            return self._reply(404, "no such route")

        try:
            payload = self._body()
        except Exception as err:
            log(f"bad json: {err}")
            return self._reply(400, "bad json")

        try:
            if route == "/ha":
                ha_alert(payload)
            else:
                speak(kuma_message(payload))
            sweep_old_audio()
            self._reply(200, "ok")
        except ValueError as err:
            log(f"rejected: {err}")
            self._reply(400, str(err))
        except Exception as err:
            log(f"failed: {err}")
            self._reply(500, "error")


if __name__ == "__main__":
    if not SECRET:
        sys.exit("PBX_ALERT_SECRET is not set")
    log(f"listening on :{PORT} as uid={os.getuid()}")
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
