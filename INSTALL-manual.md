# מרכזייה עצמית ל-ha_ivr — התקנה ידנית (בלי הסקריפט)

מדריך זה מפרט **כל** מה שהמתקין האוטומטי (`install.sh`) עושה, כדי
להקים הכל ביד, צעד-צעד: תלויות, בניית Asterisk, קובצי ההגדרה, סקריפטי
ה-AGI, הדיאלפלן, שירות ההתראות, הטראנק, וההגדרות בצד Home Assistant —
עם הנתיב המדויק של כל דבר.

---

## שני מסלולים לעוזר הקולי — חשוב להבין לפני שמתחילים

יש **שתי** דרכים להריץ את העוזר הקולי, ושתיהן מוגדרות כאן:

1. **AudioSocket (המסלול העיקרי, המומלץ).** השיחה נכנסת ל-`from-external`,
   הממסר רץ, וכשבוחרים בעוזר האודיו זורם ל-ha_ivr כ-PCM גולמי דרך
   AudioSocket — בלי קודק, בלי סבב Opus. זה מה שרוב ההתקנות משתמשות בו.

2. **SIP → העוזר המובנה של HA (מסלול גיבוי).** השיחה מועברת ב-SIP
   לשלוחת ה-VoIP המובנית של Home Assistant (`ha_endpoint`), שמריצה את
   ה-Assist דרך אינטגרציית `voip` של HA ב-Opus. זו "השלוחה המובנית
   השנייה". היא דורשת שאינטגרציית **voip** תהיה מותקנת ב-HA ומאזינה
   ב-SIP (פורט 5060), ואת ההגדרות ב-`pjsip.conf` (חלק ג׳).

שני המסלולים מוגדרים בהתקנה. אם אינך משתמש במסלול הגיבוי — אפשר לדלג
על Opus ועל `ha_endpoint`, אבל אין נזק בהשארתם.

---

## מקור הקבצים — מהיכן לוקחים את הסקריפטים

הקבצים נמצאים במאגר. השיגו אותו:

```bash
git clone https://github.com/meni123/asterisk-ha-pbx.git
cd asterisk-ha-pbx
```

הקבצים בשורש המאגר:

| קובץ | במאגר |
|---|---|
| `ha_relay.py` | `agi-bin/ha_relay.py` |
| `edge_say.sh` | `agi-bin/edge_say.sh` |
| `call_trigger.py` | `call_trigger.py` |
| תבנית config | `agi-bin/config.ini.sample` |

**מעתיקים אותם** לנתיבים שבמדריך. `edge_say.sh` מובא גם
במלואו בנספח בסוף (הוא היחיד שאולי תרצה לערוך — הקול). `ha_relay.py`
ו-`call_trigger.py` מועתקים כמו שהם, בלי עריכה.

---

## מפת הנתיבים

| רכיב | נתיב | בעלים / מצב |
|---|---|---|
| ממסר ה-AGI | `/var/lib/asterisk/agi-bin/ha_relay.py` | asterisk `755` |
| TTS מקומי | `/var/lib/asterisk/agi-bin/edge_say.sh` | asterisk `755` |
| חיבור ל-HA | `/var/lib/asterisk/agi-bin/config.ini` | asterisk `600` |
| pjsip בסיס | `/etc/asterisk/pjsip.conf` | asterisk |
| טראנקים | `/etc/asterisk/pjsip_trunks.conf` | asterisk `640` |
| דיאלפלן ראשי | `/etc/asterisk/extensions.conf` | asterisk |
| דיאלפלן התראות | `/etc/asterisk/extensions_alerts.conf` | asterisk |
| codecs / rtp / logger | `/etc/asterisk/{codecs,rtp,logger}.conf` | asterisk |
| שירות התראות | `/usr/local/lib/pbx-alert/call_trigger.py` | root `644` |
| תיקיית אודיו התראות | `/var/lib/asterisk/alert-audio/` | asterisk `750` |
| סוד התראות | `/etc/pbx-alert.env` | root `600` |
| systemd (התראות) | `/etc/systemd/system/call-trigger.service` | root `644` |

בכל הדוגמאות: `HA_IP` = כתובת Home Assistant, `BOX_IP` = כתובת שרת
Asterisk, `LAN` = הרשת (למשל `192.168.1.0/24`).

---

## חלק א׳ · תלויות

### חבילות מערכת (apt)

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential git wget curl pkg-config logrotate \
  libedit-dev libjansson-dev libsqlite3-dev libxml2-dev uuid-dev libssl-dev \
  libcurl4-openssl-dev \
  libncurses-dev libnewt-dev libsystemd-dev \
  libopus-dev libopusfile-dev libogg-dev libsrtp2-dev \
  python3 python3-pip sox libsox-fmt-all libsox-fmt-mp3
```

### חבילות Python

Debian 13 מנוהל externally (PEP-668), ולכן `--break-system-packages`:

```bash
python3 -m pip install --break-system-packages pyst2 edge-tts requests
```

- `pyst2` — `asterisk.agi` שהממסר משתמש בו.
- `edge-tts` — מנוע ה-TTS לתפריט ולהתראות.
- `requests` — הממסר פונה ל-HA ב-HTTP.

---

## חלק ב׳ · בניית Asterisk 22

AudioSocket מובנה ב-Asterisk 18+ וטעון כברירת מחדל ב-22.

```bash
cd /usr/src
curl -fsSL -O https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-22.10.1.tar.gz
tar xzf asterisk-22.10.1.tar.gz
cd asterisk-22.10.1
./configure --with-pjproject-bundled --with-jansson-bundled
make menuselect.makeopts
menuselect/menuselect --enable res_format_attr_opus menuselect.makeopts
make -j"$(nproc)"
sudo make install
sudo make samples      # רק בהתקנה ראשונה — דורס /etc/asterisk
sudo make config
sudo ldconfig
```

### משתמש השירות והבעלות

```bash
sudo groupadd -r asterisk 2>/dev/null || true
sudo useradd -r -d /var/lib/asterisk -g asterisk -s /usr/sbin/nologin asterisk 2>/dev/null || true
for d in /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk /var/run/asterisk; do
  sudo chown -R asterisk:asterisk "$d"; done
```

### כווני `asterisk.conf`

```bash
sudo sed -i 's/^;runuser = asterisk/runuser = asterisk/; s/^;rungroup = asterisk/rungroup = asterisk/' /etc/asterisk/asterisk.conf
sudo sed -i 's/^;transmit_silence = yes/transmit_silence = yes/; s/^;mindtmfduration = 80/mindtmfduration = 80/' /etc/asterisk/asterisk.conf
sudo systemctl enable asterisk
```

`transmit_silence` שומר על הקו חי בזמן עיבוד; `mindtmfduration=80`
מונע זיהוי כפול של הקשות.

### אימות ש-AudioSocket טעון

```bash
sudo asterisk -rx "module show like audiosocket"
# res_audiosocket, app_audiosocket, chan_audiosocket — שלושתם Running
```

---

## חלק ג׳ · קובצי ההגדרה של Asterisk

### `/etc/asterisk/pjsip.conf` — תעבורה + השלוחה המובנית של HA

קובץ זה מגדיר את התעבורה ואת `ha_endpoint` — שלוחת ה-VoIP של HA
(מסלול הגיבוי לעוזר). **הטראנקים אינם כאן** אלא בקובץ נפרד שנמשך בסופו.

```ini
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
local_net=LAN                 ; למשל 192.168.1.0/24

; --- ha_endpoint: שלוחת ה-VoIP המובנית של Home Assistant -------------
; מסלול הגיבוי SIP->HA-Assist. דורש שאינטגרציית voip תותקן ב-HA
; ותאזין ב-SIP 5060. ה-endpoint, ה-aor וה-identify חולקים שם.
[ha_endpoint]
type=endpoint
context=from-ha
allow=!all,opus,ulaw,alaw
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
aors=ha_endpoint

[ha_endpoint]
type=aor
contact=sip:HA_IP:5060

[ha_endpoint]
type=identify
endpoint=ha_endpoint
match=HA_IP

#include pjsip_trunks.conf
```

### `/etc/asterisk/rtp.conf`

```ini
[general]
rtpstart=10000
rtpend=20000
```

### `/etc/asterisk/codecs.conf` (רק למסלול ה-Opus; אפשר לדלג אם לא בשימוש)

```ini
[opus]
type=opus
```

### `/etc/asterisk/logger.conf` — קריטי לאבחון

בלי זה, `pjsip set logger on` ו-`agi set debug on` כותבים לקונסולה
בלבד ואין מה לקרוא אחרי שיחה תקולה. `full.log` תופס VERBOSE:

```ini
[general]
dateformat = %F %T

[logfiles]
console  => notice,warning,error,verbose
messages.log => notice,warning,error
full.log => notice,warning,error,verbose
```

### `/etc/logrotate.d/asterisk` — שלא ימלא את הדיסק

בניית מקור לא כוללת כלל rotation, ו-`full.log` גדל בלי גבול:

```
/var/log/asterisk/messages.log
/var/log/asterisk/full.log
/var/log/asterisk/queue_log
{
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /usr/sbin/asterisk -rx 'logger reload' > /dev/null 2>&1 || true
    endscript
}
```

---

## חלק ד׳ · סקריפטי ה-AGI

מעתיקים מהחבילה (ראו "מקור הקבצים") לנתיבים:

```bash
sudo mkdir -p /var/lib/asterisk/agi-bin
sudo install -o asterisk -g asterisk -m 755 agi-bin/ha_relay.py  /var/lib/asterisk/agi-bin/ha_relay.py
sudo install -o asterisk -g asterisk -m 755 agi-bin/edge_say.sh  /var/lib/asterisk/agi-bin/edge_say.sh
```

- **`ha_relay.py`** — הממסר. פונה ל-ha_ivr, מקריא, אוסף ספרה, וחוזר.
  כולל cache לפי תוכן ל-TTS של התפריט (מסונתז פעם אחת).
- **`edge_say.sh`** — הקראה מקומית (טקסט → WAV 8kHz). הקול בשורת
  `--voice` (`he-IL-AvriNeural`). מובא במלואו בנספח.

### `/var/lib/asterisk/agi-bin/config.ini` — החיבור ל-HA (מצב `600`)

```ini
[ha_ivr]
; pbx_url: מהמסך הראשון של רשומת "מרכזייה עצמית" ב-HA (כתובת פנימית + טוקן)
pbx_url = http://HA_IP:8123/api/ha_ivr/pbx/<TOKEN>
edge_say = /var/lib/asterisk/agi-bin/edge_say.sh
error_audio = beeperr
```

```bash
sudo chown asterisk:asterisk /var/lib/asterisk/agi-bin/config.ini
sudo chmod 600 /var/lib/asterisk/agi-bin/config.ini
```

את הטוקן מקבלים ממסך ההגדרות של הרשומה ב-HA (חלק ז׳).

---

## חלק ה׳ · הדיאלפלן

### `/etc/asterisk/extensions.conf`

```ini
[general]
static=yes
writeprotect=no

[globals]
HA_ENDPOINT=PJSIP/ha_endpoint
; שרת ה-AudioSocket של ha_ivr — מקור אמת יחיד לשני מסלולי ה-assist
HA_IVR_AUDIOSOCKET=HA_IP:9010

; ---- מסלול העוזר + התפריט (הפעיל, AudioSocket) ---------------------
; הפנו את הקשר הכניסה של הטראנק לכאן.
[from-external]
exten => _X.,1,Goto(s,1)
exten => s,1,NoOp(--- ha_ivr relay ---)
 same => n,NoOp(inbound CID=[${CALLERID(num)}] name=[${CALLERID(name)}] DID=${EXTEN})
 same => n,Answer()
 same => n,Set(CHANNEL(language)=he)
 same => n,Set(PBX_GOTO=)
 same => n,Set(PBX_UUID=)
 same => n,AGI(ha_relay.py)
 ; "ha-assist" = עוזר דרך AudioSocket ; יעד אחר = העברת SIP ; ריק = ניתוק
 same => n,GotoIf($["${PBX_GOTO}" = "ha-assist"]?assist)
 same => n,GotoIf($["${PBX_GOTO}" != ""]?transfer)
 same => n,Hangup()
 same => n(transfer),Dial(PJSIP/${PBX_GOTO},30,gH)
 same => n,Hangup()
 same => n(assist),AudioSocket(${PBX_UUID},${HA_IVR_AUDIOSOCKET})
 same => n,Hangup()
exten => i,1,Hangup()
exten => t,1,Hangup()

; ---- מסלול גיבוי: SIP -> השלוחה המובנית של HA (Opus) --------------
[from-trunk]
exten => _X.,1,Goto(entry,1)
exten => s,1,Goto(entry,1)
exten => entry,1,NoOp(Inbound trunk DID=${EXTEN} CID=${CALLERID(num)})
 same => n,Answer()
 same => n,Dial(${HA_ENDPOINT},60)
 same => n,Hangup()

; ---- שיחות שמגיעות מ-HA (סוגר נקי) --------------------------------
[from-ha]
exten => _X.,1,NoOp(Call from Home Assistant to ${EXTEN})
 same => n,Hangup()

; ---- דיאלפלן ההתראות ----------------------------------------------
#tryinclude "extensions_alerts.conf"
```

> `assist` משתמש ב-`${HA_IVR_AUDIOSOCKET}` — שינוי הגלובל +
> `dialplan reload` מזיז את הכתובת. אל תצרבו כתובת בשורת ה-AudioSocket.

### `/etc/asterisk/extensions_alerts.conf`

```ini
[ha-outbound]
; חצי החיוג. <phone> מהקובץ, הטראנק מ-${HA_TRUNK} שנבחר ב-HA.
exten => _X.,1,NoOp(HA alert -> ${EXTEN} via trunk ${HA_TRUNK})
 same => n,GotoIf($["${HA_TRUNK}" = ""]?notrunk)
 same => n,Dial(PJSIP/${EXTEN}@${HA_TRUNK},60)
 same => n,Hangup()
 same => n(notrunk),NoOp(no HA_TRUNK supplied — dropped)
 same => n,Hangup()

[tts-alerts]
; חצי ההקראה. מנגן WAV ש-call_trigger סינתז מראש (מיידי, cache).
; ALERT_FILE הוא נתיב תחת /var/lib/asterisk/alert-audio (לא /tmp!),
; בנוי מ-hash של התוכן — אף פעם לא טקסט חופשי; שום shell כאן.
exten => s,1,NoOp(TTS alert: ${ALERT_FILE})
 same => n,GotoIf($["${ALERT_FILE}" = ""]?drop)
 same => n,Answer()
 same => n,Wait(1)
 same => n,Playback(${ALERT_FILE})
 same => n,Hangup()
 same => n(drop),NoOp(no ALERT_FILE — dropped)
 same => n,Hangup()
```

---

## חלק ו׳ · השרת שמאזין להתראות (call_trigger)

זהו **השרת שמקבל את ההתראות מ-HA**. ישות ה-`notify` של ha_ivr פונה
אליו ב-HTTP, והוא מחייג ומקריא:

```
HA (ישות notify)  ──POST /ha──▶  call_trigger.py  (מאזין BOX_IP:5000)
                                   │ מסנתז WAV מראש (alert-audio)
                                   │ מפיל call file
                                   ▼
                                 Asterisk מחייג ומקריא (tts-alerts)
```

> **חייב לרוץ על מכונה עם Asterisk וטראנק יוצא** — הוא מפיל call files
> ש-Asterisk מרים. שרת נפרד בלי Asterisk יקבל את ה-POST אך לא יחייג.

### התיקייה המשותפת לאודיו

`asterisk.service` רץ עם `PrivateTmp=true` — ה-/tmp שלו פרטי. לכן
קובצי ההתראה ש-`call_trigger` (שירות אחר) מייצר **חייבים** לשבת
בתיקייה משותפת שאסטריק רואה, לא ב-/tmp:

```bash
sudo mkdir -p /var/lib/asterisk/alert-audio
sudo chown asterisk:asterisk /var/lib/asterisk/alert-audio
sudo chmod 750 /var/lib/asterisk/alert-audio
```

(התפריט לעומת זאת עובד ב-/tmp: `ha_relay.py` רץ **בתוך** תהליך
Asterisk וחולק את אותו /tmp פרטי.)

### הצבת השירות

```bash
sudo mkdir -p /usr/local/lib/pbx-alert
sudo install -m 644 call_trigger.py /usr/local/lib/pbx-alert/call_trigger.py
```

### `/etc/pbx-alert.env` — מצב `600`

```ini
PBX_ALERT_SECRET=<בחרו-סוד-אקראי-חזק>
PBX_ALERT_PORT=5000
# מזהה מתקשר בשיחות התראה כשהמפיק אינו שולח; ריק = <0000000000>
PBX_ALERT_CALLERID=<המספר-שיוצג>
```

```bash
sudo chown root:root /etc/pbx-alert.env
sudo chmod 600 /etc/pbx-alert.env
```

> ה-`PBX_ALERT_SECRET` **חייב** להיות זהה בית-בבית לשדה "סוד שירות
> ההתראות" ב-HA, אחרת כל בקשה חוזרת `403`.

### `/etc/systemd/system/call-trigger.service`

```ini
[Unit]
Description=PBX alert webhook (Home Assistant)
After=network.target asterisk.service

[Service]
User=asterisk
Group=asterisk
EnvironmentFile=/etc/pbx-alert.env
Environment="REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
ExecStart=/usr/bin/python3 /usr/local/lib/pbx-alert/call_trigger.py
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now call-trigger
sudo systemctl status call-trigger        # Active: running
```

מאזין על `BOX_IP:5000`, מסלול `/ha`. מסנתז מראש ל-`alert-audio`,
מפיל call file ל-`/var/spool/asterisk/outgoing/`.

---

## חלק ז׳ · טראנק הספק

`/etc/asterisk/pjsip_trunks.conf` (מצב `640`, asterisk:asterisk).
דוגמה לטראנק שנרשם:

```ini
[mytrunk-reg]
type=registration
transport=transport-udp
outbound_auth=mytrunk-auth
server_uri=sip:sip.provider.com
client_uri=sip:USERNAME@sip.provider.com
retry_interval=60
expiration=60
line=yes
endpoint=mytrunk

[mytrunk-auth]
type=auth
auth_type=userpass
username=USERNAME
password=SECRET

[mytrunk-aor]
type=aor
contact=sip:sip.provider.com
; בלי qualify_frequency: ספקים רבים (ימות) מתעלמים מ-OPTIONS וה-AOR
; מסומן Unavailable, ואז שיחות יוצאות נכשלות. הרישום מחזיק אותו חי.

[mytrunk]
type=endpoint
transport=transport-udp
context=from-external          ; <-- מסלול ha_ivr (תפריט + עוזר)
disallow=all
allow=alaw
allow=ulaw
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
aors=mytrunk-aor
outbound_auth=mytrunk-auth
from_user=USERNAME
from_domain=sip.provider.com

[mytrunk-identify]
type=identify
endpoint=mytrunk
match=sip.provider.com
```

`context=from-external` = המסלול של ha_ivr. (לגיבוי SIP→HA-VoIP:
`from-trunk`.) טעינה: `sudo asterisk -rx "pjsip reload"` ואז
`pjsip show registrations` (Registered).

> **שים לב:** השתמשו בטראנק הייעודי למרכזייה הזאת. ספק מנתב שיחות
> נכנסות למי שנרשם אחרון — אם אותם פרטים כבר רשומים במרכזייה אחרת
> פעילה, השיחות שלה יעברו לכאן.

---

## חלק ח׳ · הגדרות בצד Home Assistant

ברשומה **מרכזייה עצמית**:

### החיבור והעוזר (AudioSocket)

1. **המסך הראשון** מציג את `pbx_url` (כתובת פנימית + טוקן) — העתיקו
   ל-`config.ini` (חלק ד׳).
2. **הגדרות התפריט → כתובת/פורט האזנה:** `0.0.0.0` (או `127.0.0.1`
   אם אותה קופסה) ו-`9010`. הפורט חייב להתאים ל-`HA_IVR_AUDIOSOCKET`.
3. **פריט העוזר** (כפתור `+`): פריט "מעבר" שהיעד שלו בדיוק `ha-assist`.
4. **טווחי IP / מספרים מורשים** — מומלץ להגביל ל-LAN.

### מסלול הגיבוי (השלוחה המובנית של HA) — אופציונלי

אם רוצים גם את מסלול ה-SIP→HA-VoIP: התקינו את אינטגרציית **voip**
ב-HA (הגדרות → הוסף אינטגרציה → Voice over IP), ודאו שהיא מאזינה
ב-SIP 5060, וכוונו טראנק להקשר `from-trunk` במקום `from-external`.

### ההתראות

**הגדרות התפריט:**

| שדה | ערך |
|---|---|
| כתובת שירות ההתראות | `http://BOX_IP:5000/ha` |
| טראנק יוצא להתראות | שם הטראנק (למשל `mytrunk`) |
| סוד שירות ההתראות | הערך מ-`/etc/pbx-alert.env` (זהה!) |

ואז הוסיפו **נמענים** (כפתור `+`) — כל אחד הופך לישות `notify`.

---

## חלק ט׳ · אימות מקצה-לקצה

```bash
sudo asterisk -rx "module show like audiosocket"     # 3 Running
sudo systemctl status asterisk call-trigger          # שניהם active
# תפריט:
curl -X POST "http://HA_IP:8123/api/ha_ivr/pbx/<TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"caller":"0500000000","path":"","step":1}'     # מחזיר JSON תפריט
```

ואז: שיחה → תפריט → מקש העוזר → שיחה עם Assist. התראה מ-HA → צלצול
והקראה. ביומן HA: `AudioSocket: line ... for <מתקשר>`,
`PBX alert -> HTTP 200`. בשרת: `AudioSocket(...:9010)`,
`queued ha call ... via <trunk>`.

---

## פתרון תקלות

| תופעה | סיבה / פתרון |
|---|---|
| העוזר לא מתחבר, התפריט כן | האזנה `127.0.0.1` בעוד Asterisk במארח אחר → `0.0.0.0`; פורט תואם; פיירוול |
| "המספר לא מזוהה" בתפריט | CID ריק — הספק שולח ב-P-Asserted-Identity; הוסיפו `trust_id_inbound=yes` ל-endpoint הטראנק |
| התראה `403` | הסוד לא תואם בין `/etc/pbx-alert.env` ל-HA |
| התראה `200` אך אין שיחה | שם טראנק שגוי או אין מסלול יוצא |
| התראה עונה בשקט/נופלת | תיקיית `alert-audio` חסרה (PrivateTmp) — ראו חלק ו׳ |
| התפריט באיחור בפעם ראשונה | סינתזת edge-tts דרך הרשת; ה-cache הופך אותה מיידית |
| אין מה לקרוא ביומן אחרי שיחה | `logger.conf` חסר — full.log לא תופס VERBOSE (חלק ג׳) |
| שיחה לא מגיעה ל-Asterisk | שכבת הספק/הטראנק (failover) — לא ha_ivr |

---

## אבטחה

- `config.ini` ו-`pbx-alert.env` במצב `600`.
- AudioSocket הוא TCP גולמי בלי הצפנה/אימות מעבר ל-UUID — האזינו רק
  על ה-LAN וחסמו את הפורט מבחוץ.
- אל תכניסו טוקנים אמיתיים לקבצים שנכנסים לריפו — placeholder בלבד.

---

## נספח · `edge_say.sh` במלואו

```bash
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# תעודות CA (עוקף מסנני רשת עבור מנוע ה-Edge)
export REQUESTS_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
export WEBSOCKET_CLIENT_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

TEXT="$1"
# $2 עם "/" = נתיב מלא (התראות, תחת alert-audio); בלי = שם תחת /tmp (תפריט).
# קבצים משותפים עם Asterisk לא יכולים לשבת ב-/tmp בגלל PrivateTmp.
case "$2" in
    */*) FILENAME="$2" ;;
    *)   FILENAME="/tmp/$2" ;;
esac
RAW_FILE="${FILENAME}_raw.$$.mp3"
TMP_WAV="${FILENAME}.$$.tmp.wav"
FINAL_FILE="${FILENAME}.wav"
LOG_FILE="/tmp/edge_error.log"

if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    : > "$LOG_FILE"
fi

edge-tts --text "$TEXT" --voice he-IL-AvriNeural --write-media "$RAW_FILE" 2>> "$LOG_FILE"

if [ -s "$RAW_FILE" ]; then
    sox "$RAW_FILE" -r 8000 -c 1 -b 16 "$TMP_WAV" 2>> "$LOG_FILE"
    rm -f "$RAW_FILE"
    if [ -s "$TMP_WAV" ]; then
        chmod 644 "$TMP_WAV"
        mv -f "$TMP_WAV" "$FINAL_FILE"
    else
        echo "ERROR: sox produced no output for ${FILENAME}." >> "$LOG_FILE"; rm -f "$TMP_WAV"; exit 1
    fi
else
    echo "ERROR: File was not created. Edge-TTS failed." >> "$LOG_FILE"; rm -f "$RAW_FILE"; exit 1
fi
```

`ha_relay.py` ו-`call_trigger.py` — מהחבילה (`pbx-build/agi-bin/` ו-
`pbx-build/`), מועתקים כמו שהם.
