#!/usr/bin/env python3
"""ממסר בין Asterisk ל-ha_ivr — התפריט חי ב-Home Assistant.

מחזור אחד שפונה ל-ha_ivr, מקריא את מה שהוא אומר, אוסף ספרה, וחוזר.
אין כאן ישויות, מבנה תפריט או לוגיקה — כל זה מוגדר בממשק של ha_ivr.
מה שנשאר כאן: הטלפוניה, וה-TTS המקומי.

התשובה מ-ha_ivr קובעת את ההמשך: `menu` = לאסוף ספרה ולשוב; `goto` =
להעביר ליעד (משתנה `PBX_GOTO`); ואם היעד הוא העוזר הקולי, מצורף גם
`uuid` (משתנה `PBX_UUID`) שהדיאלפלן מעביר ל-AudioSocket.

הדיאלפלן קורא לזה פעם אחת בכניסה לשיחה:

    exten => s,1,Answer()
     same => n,Set(PBX_GOTO=)
     same => n,Set(PBX_UUID=)
     same => n,AGI(ha_relay.py)
     same => n,GotoIf($["${PBX_GOTO}" = "ha-assist"]?assist)  ; עוזר קולי
     same => n,GotoIf($["${PBX_GOTO}" != ""]?transfer)        ; מעבר SIP
     same => n,Hangup()

הגדרות ב-config.ini (mode 600, בבעלות asterisk):

    [ha_ivr]
    pbx_url = http://<HA>:8123/api/ha_ivr/pbx/<token>
    edge_say = /var/lib/asterisk/agi-bin/edge_say.sh
    error_audio = beeperr
"""

from __future__ import annotations

import configparser
import os
import hashlib
import subprocess
import sys
import time

import requests
from asterisk.agi import AGI

# ----------------------------------------------------------------------
# הגדרות

config = configparser.ConfigParser(inline_comment_prefixes=(";", "#"))
config.read(os.path.join(os.path.dirname(__file__), "config.ini"))

_ha = config["ha_ivr"] if config.has_section("ha_ivr") else {}
PBX_URL = str(_ha.get("pbx_url", "")).rstrip("/")
EDGE_SAY = _ha.get("edge_say", "/var/lib/asterisk/agi-bin/edge_say.sh")
# הצליל שמושמע כשמשהו נכשל — נשמע כדי שהמתקשר לא יקבל שקט מוחלט.
ERROR_AUDIO = _ha.get("error_audio", "beeperr")

HTTP_TIMEOUT = 5
# תקרת סבבים, כדי ששרשרת תשובות תקולה לא תיצור לולאה אינסופית.
# ha_ivr עצמו מנתק אחרי מספר השמעות ללא הקשה; זו חגורת ביטחון נוספת.
MAX_STEPS = 40

agi = AGI()

# רק ספרות — ha_ivr משווה את המתקשר ל-9 הספרות האחרונות.
CALLER = "".join(c for c in agi.env.get("agi_callerid", "") if c.isdigit())
# נרשם ללוג בכל שיחה: כשמסנן לפי מספר ב-ha_ivr עונה "המספר אינו מזוהה",
# זו השורה שמכריעה אם הבעיה כאן או בהגדרות שב-HA. בלעדיה צריך להדליק
# agi set debug on ולבקש מהמתקשר לחייג שוב.
agi.verbose(f"ha_ivr: caller={CALLER or '(empty)'} last9={CALLER[-9:] or '(none)'}")

session = requests.Session()


# ----------------------------------------------------------------------
# הקראה מקומית — edge_say.sh שלך

def tts(text: str) -> str:
    """טקסט → קובץ wav, ומחזיר את נתיבו בלי הסיומת (כמו ש-Asterisk רוצה).

    כישלון מחזיר את צליל השגיאה, כדי שהמתקשר לא ישמע שקט.
    """
    # cache לפי תוכן: אותו טקסט מסונתז פעם אחת ומושמע מיד בכל שיחה
    # הבאה. תפריט קבוע נהיה מיידי; רק טקסט חדש עולה לרשת.
    key = hashlib.md5(text.encode("utf-8")).hexdigest()[:16]
    hint = f"ha_ivr_tts_{key}"
    produced = f"/tmp/{hint}.wav"
    if os.path.exists(produced):
        return f"/tmp/{hint}"
    try:
        # תקרה רחבה: מנוע הקראה מקומי מסנתז כ-20 תווים לשנייה, ולכן
        # 15 שניות נגמרות סביב 280 תווים — פחות מתפריט ארוך או
        # משלוחה שמקריאה רשימה. ההמתנה משולמת פעם אחת, כי התוצאה
        # נשמרת ב-cache לפי תוכן.
        subprocess.run(["/bin/bash", EDGE_SAY, text, hint], timeout=60, check=False)
    except Exception as err:  # noqa: BLE001
        agi.verbose(f"TTS failed: {err}")
    return f"/tmp/{hint}" if os.path.exists(produced) else ERROR_AUDIO


# ----------------------------------------------------------------------
# בקשה ל-ha_ivr

def ask(path: str, digit: str, step: int) -> dict | None:
    """שולח את מצב השיחה ל-ha_ivr ומחזיר את הפעולה הבאה, או None בכשל."""
    try:
        resp = session.post(
            PBX_URL,
            json={"caller": CALLER, "path": path, "digit": digit, "step": step},
            timeout=HTTP_TIMEOUT,
        )
        resp.raise_for_status()
        return resp.json()
    except Exception as err:  # noqa: BLE001
        agi.verbose(f"ha_ivr request failed: {err}")
        return None


# ----------------------------------------------------------------------

def main() -> None:
    if not PBX_URL:
        agi.verbose("ha_ivr: pbx_url is not configured in config.ini")
        agi.stream_file(ERROR_AUDIO)
        return

    path, digit, step = "", "", 1
    for _ in range(MAX_STEPS):
        resp = ask(path, digit, step)
        if not resp:
            agi.stream_file(ERROR_AUDIO)
            return

        say = str(resp.get("say", "")).strip()
        wav = tts(say) if say else None
        timeout_ms = int(resp.get("timeout", 10) or 10) * 1000

        if resp.get("menu"):
            # השמעה עם קליטת ספרה אחת — הקשה קוטעת את ההשמעה (barge-in).
            if wav:
                digit = agi.get_data(wav, timeout_ms, 1) or ""
            else:
                digit = agi.wait_for_digit(timeout_ms) or ""
            path = str(resp.get("path", ""))
            step += 1
            continue

        # עלה, מעבר, או ניתוק — השמע וסיים.
        if wav:
            agi.stream_file(wav)
        if resp.get("goto"):
            # הדיאלפלן יעביר ליעד הזה. שלוחת ה-voip של HA, למשל.
            agi.set_variable("PBX_GOTO", str(resp["goto"]))
            if resp.get("uuid"):
                agi.set_variable("PBX_UUID", str(resp["uuid"]))
        return


if __name__ == "__main__":
    try:
        main()
    except Exception as err:  # noqa: BLE001 — כשל לא אמור לנתק בלי צליל
        agi.verbose(f"ha_relay crashed: {err}")
        try:
            agi.stream_file(ERROR_AUDIO)
        except Exception:  # noqa: BLE001
            pass
        sys.exit(0)
