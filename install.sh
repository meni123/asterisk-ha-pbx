#!/usr/bin/env bash
#
# install.sh — build Asterisk 22 LTS from source on bare Debian 13 (trixie)
# and prepare it to host the HA_IVR voice-assistant integration.
#
# Idempotent: safe to run twice. Refuses to run without root, and refuses on a
# box that already has Asterisk unless --force. Logs to /var/log/pbx-install.log.
# The Opus transcoder is installed (validated build gate) but the PRIMARY path
# to the assistant is AudioSocket (raw PCM, no codec) — see INSTALL.md.
#
# Usage:  sudo ./install.sh --ha <ip> [--force]
#   --ha <ip>  Home Assistant address (REQUIRED; local_net derives from it)
#   --force    proceed even if Asterisk is already installed
#
# Front-end: `sudo ./pbx install` asks for the address and calls this.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned versions (do not float)
ASTERISK_VERSION="22.10.1"
ASTERISK_SHA256="0953564c44fa49827f3c9d70ca6e80db83828c9848440852c6be44c961855353"
OPUS_PKG="codec_opus-22.0_1.3.0-x86_64"            # pinned Digium/Sangoma binary
OPUS_BASE="https://downloads.digium.com/pub/telephony/codec_opus/asterisk-22.0/x86-64"
AST_BASE="https://downloads.asterisk.org/pub/telephony/asterisk/releases"
# Per-file md5sums from the vendor manifest.xml:
OPUS_SO_MD5="dfa5802e7c7540cda4a2b0ec6ec677a1"
OGG_SO_MD5="56cd086e220cac80acdbaa41c736212e"

SRC_DIR="/usr/src"
AST_SRC="${SRC_DIR}/asterisk-${ASTERISK_VERSION}"
MOD_DIR="/usr/lib/asterisk/modules"
LOG="/var/log/pbx-install.log"
FORCE=0
HA=""                                             # Home Assistant address — REQUIRED via --ha
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # repo dir (agi-bin/ lives here)

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --ha)    HA="${2:?--ha needs an address}"; shift ;;
        *)       echo "unknown argument: $1  (usage: sudo ./install.sh --ha <ip> [--force])" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# logging helpers
say()  { echo -e "\n=== $* ==="; }
info() { echo "  $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# No site address is baked into this script: the operator supplies it, so the
# published installer carries nobody's network. (`pbx install` asks for it.)
[ -n "$HA" ] || die "--ha <ip> is required — the Home Assistant address (e.g. --ha 192.168.1.10)"
# pjsip local_net: derive the /24 from the HA address (flat-LAN assumption; a
# routed site edits pjsip.conf after install).
LOCAL_NET="$(echo "$HA" | awk -F. '{print $1"."$2"."$3".0/24"}')"

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo ./install.sh)"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

say "pbx-install starting $(date '+%F %T')  (Asterisk ${ASTERISK_VERSION})"

if command -v asterisk >/dev/null 2>&1 && [ "$FORCE" -ne 1 ]; then
    die "Asterisk already present ($(asterisk -V 2>/dev/null)). Re-run with --force."
fi

# ---------------------------------------------------------------------------
# P1 — dependencies (minimal, verified list — NOT install_prereq, which drags
# in dozens of optional libs and the module log-noise that comes with them).
say "P1 — build + runtime dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  build-essential git wget curl pkg-config logrotate \
  libedit-dev libjansson-dev libsqlite3-dev libxml2-dev uuid-dev libssl-dev \
  libcurl4-openssl-dev \
  libncurses-dev libnewt-dev libsystemd-dev \
  libopus-dev libopusfile-dev libogg-dev libsrtp2-dev \
  python3 python3-pip python3-requests sox libsox-fmt-all libsox-fmt-mp3
# HA_IVR runtime python deps (Debian 13 is PEP-668 externally-managed).
info "installing HA_IVR python deps (pyst2, edge-tts)"
python3 -m pip install --break-system-packages --quiet pyst2 edge-tts
info "gcc: $(gcc -dumpversion)  libopus: $(pkg-config --modversion opus)"

# ---------------------------------------------------------------------------
# P2 — source
say "P2 — fetch and verify source"
cd "$SRC_DIR"
if [ ! -f "asterisk-${ASTERISK_VERSION}.tar.gz" ]; then
    curl -fsSL -O "${AST_BASE}/asterisk-${ASTERISK_VERSION}.tar.gz"
fi
echo "${ASTERISK_SHA256}  asterisk-${ASTERISK_VERSION}.tar.gz" | sha256sum -c - \
    || die "asterisk tarball checksum mismatch"
[ -d "$AST_SRC" ] || tar xzf "asterisk-${ASTERISK_VERSION}.tar.gz"
[ "$(cat "${AST_SRC}/.version")" = "$ASTERISK_VERSION" ] || die "version mismatch in source tree"

# ---------------------------------------------------------------------------
# P3/P4 — configure + menuselect
say "P3 — configure (bundled pjproject + jansson)"

# Pre-seed the third-party download cache BEFORE configure.
#
# configure builds the bundled jansson/pjproject/libjwt, and each fetches its
# tarball from raw.githubusercontent.com using the build's own
# `wget -q -O-` with ONE retry and no resume. A single blip kills the whole
# configure. Example of the failure this guards against:
#     [jansson]  Retrying download
#     make: *** [Makefile:68: /tmp/jansson-2.15.0.tar.bz2] Error 4
#     configure: Unable to configure /usr/src/asterisk-22.10.1/third-party/jansson
# Minutes later the URL returned HTTP 200 and the md5 matched exactly, so the
# failure was transient — which is precisely what a 20-minute build must not
# depend on. Fetch each tarball here with curl's retry/backoff, verify it
# against the md5 the source tree ships, and point the build at the cache with
# EXTERNALS_CACHE_DIR so it downloads nothing itself. Also makes a re-run and
# an offline rebuild cheap.
EXTERNALS_CACHE="${SRC_DIR}/asterisk-externals"
mkdir -p "$EXTERNALS_CACHE"
seed_external() {   # seed_external <name> <version> <tarball>
    local name="$1" version="$2" file="$3"
    local md5file="${AST_SRC}/third-party/${name}/${file}.md5"
    local dest="${EXTERNALS_CACHE}/${file}"
    # Not every entry in versions.mak ships an md5 / is actually built; without
    # one we cannot verify, so leave that dep to the build's own downloader.
    [ -f "$md5file" ] || { info "no md5 shipped for ${file} — left to the build"; return 0; }
    local want; want="$(awk '{print $1}' "$md5file")"
    if [ -f "$dest" ] && [ "$(md5sum "$dest" | awk '{print $1}')" = "$want" ]; then
        info "cached: ${file}"
        return 0
    fi
    curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused \
         -o "${dest}.part" \
         "https://raw.githubusercontent.com/asterisk/third-party/master/${name}/${version}/${file}" \
        || die "could not download ${file} (network?)"
    [ "$(md5sum "${dest}.part" | awk '{print $1}')" = "$want" ] \
        || { rm -f "${dest}.part"; die "${file} md5 mismatch — download corrupt or tampered"; }
    mv -f "${dest}.part" "$dest"       # atomic: the build never sees a partial file
    info "fetched: ${file}"
}
# Versions come from the source tree, so they track the pinned Asterisk release
# instead of being duplicated here.
# shellcheck source=/dev/null
. "${AST_SRC}/third-party/versions.mak"
seed_external jansson   "${JANSSON_VERSION}"   "jansson-${JANSSON_VERSION}.tar.bz2"
seed_external pjproject "${PJPROJECT_VERSION}" "pjproject-${PJPROJECT_VERSION}.tar.bz2"
seed_external libjwt    "${LIBJWT_VERSION}"    "libjwt-${LIBJWT_VERSION}.tar.gz"
export EXTERNALS_CACHE_DIR="$EXTERNALS_CACHE"

cd "$AST_SRC"
./configure --with-pjproject-bundled --with-jansson-bundled

say "P4 — menuselect (res_format_attr_opus + res_curl on; external codec_opus off)"
# Regenerate rather than reuse: on a resumed run a stale menuselect.makeopts
# keeps the module states from the PREVIOUS configure, so a dependency fixed
# since then would still read as failed.
rm -f menuselect.makeopts
make menuselect.makeopts
# res_curl is NOT optional: the pinned codec_opus.so binary links libcurl and
# needs res_curl loaded to register its translator. Do not "clean it up".
menuselect/menuselect --enable res_format_attr_opus --enable res_curl menuselect.makeopts

# menuselect --enable CANNOT override a failed dependency, and it exits 0 either
# way — so a missing libcurl4-openssl-dev silently produced a build with no
# res_curl, and the failure only surfaced 20 minutes later as an empty Opus
# translation table at the P7 gate. Assert it here.
if grep -q "MENUSELECT_DEPSFAILED=.*res_curl" menuselect.makeopts; then
    die "res_curl dependency failed — libcurl dev headers missing. Without it codec_opus loads but registers no translator and P7 will fail."
fi
if grep -qE "^MENUSELECT_RES=.*\bres_curl\b" menuselect.makeopts; then
    die "res_curl is disabled in menuselect.makeopts — it must be built for codec_opus to work"
fi
info "menuselect: res_curl enabled, res_format_attr_opus enabled"

# ---------------------------------------------------------------------------
# P5 — build + install
say "P5 — build + install"
make -j"$(nproc)"
make install
# make samples is destructive to /etc/asterisk — only on a first install.
if [ ! -f /etc/asterisk/asterisk.conf ]; then
    make samples
fi
make config
ldconfig
info "installed: $(/usr/sbin/asterisk -V)"

# ---------------------------------------------------------------------------
# P5b — pinned Opus transcoder binary (closed blob; validated build gate +
# keeps the SIP->HA-VoIP fallback path available). Verified vs manifest md5.
say "P5b — install pinned Opus binary ${OPUS_PKG}"
cd "$SRC_DIR"
if [ ! -f "${OPUS_PKG}.tar.gz" ]; then
    curl -fsSL -O "${OPUS_BASE}/${OPUS_PKG}.tar.gz"
fi
rm -rf "${SRC_DIR}/opus_pinned" && mkdir -p "${SRC_DIR}/opus_pinned"
tar xzf "${OPUS_PKG}.tar.gz" -C "${SRC_DIR}/opus_pinned"
OSRC="${SRC_DIR}/opus_pinned/${OPUS_PKG}"
echo "${OPUS_SO_MD5}  ${OSRC}/codec_opus.so"       | md5sum -c - || die "codec_opus.so md5 mismatch"
echo "${OGG_SO_MD5}  ${OSRC}/format_ogg_opus.so"   | md5sum -c - || die "format_ogg_opus.so md5 mismatch"
install -m 0755 "${OSRC}/codec_opus.so"      "${MOD_DIR}/codec_opus.so"
install -m 0755 "${OSRC}/format_ogg_opus.so" "${MOD_DIR}/format_ogg_opus.so"
DOC=/var/lib/asterisk/documentation/thirdparty
mkdir -p "${DOC}/codec_opus"
install -m 0644 "${OSRC}/codec_opus_config-en_US.xml" "${DOC}/codec_opus_config-en_US.xml"
install -m 0644 "${OSRC}/LICENSE" "${DOC}/codec_opus/LICENSE"
install -m 0644 "${OSRC}/README"  "${DOC}/codec_opus/README"

# ---------------------------------------------------------------------------
# block codec_opus telemetry (phones home to stats.asterisk.org every 24h)
say "block Opus telemetry (stats.asterisk.org)"
if ! grep -q "stats.asterisk.org" /etc/hosts; then
    printf '0.0.0.0 stats.asterisk.org  # block codec_opus telemetry (pbx-build)\n:: stats.asterisk.org  # block codec_opus telemetry IPv6 (pbx-build)\n' >> /etc/hosts
fi

# ---------------------------------------------------------------------------
# P6 — service account, ownership, systemd
say "P6 — asterisk user, ownership, systemd"
getent group asterisk >/dev/null || groupadd -r asterisk
id asterisk >/dev/null 2>&1 || useradd -r -d /var/lib/asterisk -g asterisk -s /usr/sbin/nologin asterisk
for d in /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk /var/run/asterisk; do
    [ -d "$d" ] && chown -R asterisk:asterisk "$d"
done
sed -i 's/^;runuser = asterisk/runuser = asterisk/; s/^;rungroup = asterisk/rungroup = asterisk/' /etc/asterisk/asterisk.conf
grep -q '^runuser = asterisk' /etc/asterisk/asterisk.conf || \
    sed -i '/^\[options\]/a runuser = asterisk\nrungroup = asterisk' /etc/asterisk/asterisk.conf
# asterisk.conf tunables (idempotent)
sed -i 's/^;transmit_silence = yes/transmit_silence = yes/; s/^;mindtmfduration = 80/mindtmfduration = 80/' /etc/asterisk/asterisk.conf
# systemd unit (vendor contrib) — needs libsystemd (built in P1). Enable RuntimeDirectory.
install -m 0644 "${AST_SRC}/contrib/systemd/asterisk.service" /etc/systemd/system/asterisk.service
sed -i 's|^#RuntimeDirectory=asterisk|RuntimeDirectory=asterisk|' /etc/systemd/system/asterisk.service
update-rc.d asterisk remove >/dev/null 2>&1 || true      # drop SysV, avoid double mgmt
systemctl daemon-reload
systemctl enable asterisk >/dev/null 2>&1

# ---------------------------------------------------------------------------
# P8 — base configuration
say "P8 — base configuration"
write_cfg() {  # write_cfg <path> <heredoc-on-stdin>; backs up any existing file
    local f="$1"
    if [ -f "$f" ]; then
        cp -a "$f" "${f}.bak-$(date +%Y%m%d-%H%M%S)"
        # keep the 3 newest backups; repeated runs must not accumulate forever
        ls -1t "${f}".bak-* 2>/dev/null | tail -n +4 | xargs -r rm -f
    fi
    cat > "$f"
    chown asterisk:asterisk "$f"
}

write_cfg /etc/asterisk/codecs.conf <<'EOF'
; codecs.conf — Opus is NOT on the assistant path (that is AudioSocket/PCM).
; This tunes the codec_opus encoder only for the SIP->HA-VoIP fallback.
; In Asterisk 22, max_playback_rate is NOT advertised in SDP (verified), so the
; HA-VoIP leg is opus@48000 regardless; standard defaults interoperate best.
[opus]
type=opus
EOF

write_cfg /etc/asterisk/rtp.conf <<'EOF'
[general]
rtpstart=10000
rtpend=20000
EOF

# logger.conf — without this the sample config logs only NOTICE/WARNING/ERROR to
# messages.log, and everything at VERBOSE goes to the interactive console only.
# That means `pjsip set logger on` and `agi set debug on` — the two tools you
# actually need to debug a call — write to NO file, so there is nothing to read
# afterwards, so a caller-ID or SIP trace has nothing to show.
write_cfg /etc/asterisk/logger.conf <<'EOF'
[general]
dateformat = %F %T

[logfiles]
console  => notice,warning,error,verbose
; messages.log keeps the quiet operational record.
messages.log => notice,warning,error
; full.log is the one you read after a bad call: it captures VERBOSE, so SIP
; traces (pjsip set logger on) and AGI traffic (agi set debug on) are preserved.
; Rotated weekly by /etc/logrotate.d/asterisk.
full.log => notice,warning,error,verbose
EOF

# log rotation — a source build ships no logrotate rule, so /var/log/asterisk/full
# and messages grow without bound and eventually fill the disk (the #1 long-term
# killer of an untouched box). Install our rule ONLY if none exists — never
# clobber one a package may have placed. postrotate tells Asterisk to reopen its
# log files (a plain rotate would leave it writing to the moved inode).
if [ ! -f /etc/logrotate.d/asterisk ]; then
    cat > /etc/logrotate.d/asterisk <<'EOF'
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
EOF
    chown root:root /etc/logrotate.d/asterisk
    chmod 644 /etc/logrotate.d/asterisk
    info "installed /etc/logrotate.d/asterisk (weekly, keep 8, compressed)"
else
    info "/etc/logrotate.d/asterisk already present — left as-is"
fi

write_cfg /etc/asterisk/pjsip.conf <<EOF
;=====================================================================
; pjsip.conf — base. Trunks live in pjsip_trunks.conf (setup-trunk.py);
; never edit trunks here. No external_media_address: NAT media is handled
; by rtp_symmetric + the assistant greeting opening the pinhole (verified),
; which is dynamic-public-IP proof.
;=====================================================================
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
local_net=${LOCAL_NET}

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
contact=sip:${HA}:5060

[ha_endpoint]
type=identify
endpoint=ha_endpoint
match=${HA}

#include pjsip_trunks.conf
EOF

if [ ! -f /etc/asterisk/pjsip_trunks.conf ]; then
    echo "; Managed by setup-trunk.py — provider trunks only. Do not edit by hand." \
        > /etc/asterisk/pjsip_trunks.conf
fi
chown asterisk:asterisk /etc/asterisk/pjsip_trunks.conf
chmod 640 /etc/asterisk/pjsip_trunks.conf

write_cfg /etc/asterisk/extensions.conf <<EOF
[general]
static=yes
writeprotect=no

[globals]
HA_ENDPOINT=PJSIP/ha_endpoint
HA_IVR_AUDIOSOCKET=${HA}:9010   ; HA_IVR AudioSocket server (host:port, default 9010)

; [from-trunk] — SIP -> HA VoIP integration (Opus fallback). Answer() before
; Dial() so the assistant's first words are not swallowed. Both _X. and s
; funnel into the named 'entry' exten — a Goto cannot target a pattern
; (Goto(_X.,1) never matches: the literal "_X." starts with '_', not a digit).
[from-trunk]
exten => _X.,1,Goto(entry,1)
exten => s,1,Goto(entry,1)
exten => entry,1,NoOp(Inbound trunk DID=\${EXTEN} CID=\${CALLERID(num)})
 same => n,Answer()
 same => n,Dial(\${HA_ENDPOINT},60)
 same => n,Hangup()

[from-ha]
exten => _X.,1,NoOp(Call from Home Assistant to \${EXTEN})
 same => n,Hangup()

; [ha-assist] — AudioSocket connectivity probe ONLY. It mints its own UUID,
; which ha_ivr rejects (only UUIDs registered via the relay's goto answer are
; accepted), so it can never carry a full assistant session. It proves TCP
; reachability to the AudioSocket server and nothing more. Real sessions go
; through [from-external]. (The "ha-assist" STRING the relay compares against
; is ha_ivr's marker, unrelated to this context's name.)
[ha-assist]
exten => _X.,1,Goto(assist,1)
exten => s,1,Goto(assist,1)
exten => assist,1,NoOp(AudioSocket probe: \${CALLERID(num)})
 same => n,Answer()
 same => n,Set(ASUUID=\${UUID()})
 same => n,AudioSocket(\${ASUUID},\${HA_IVR_AUDIOSOCKET})
 same => n,Hangup()

; [from-external] — ACTIVE HA_IVR integration (menu relay + voice assistant).
; Thin transport: Answer, run the AGI relay (HTTP to ha_ivr), then stream the
; assistant over AudioSocket, transfer via SIP, or hang up — all decided by
; ha_ivr. Point a trunk's inbound context here (setup-trunk.py option 1).
; Requires in agi-bin/: ha_relay.py, edge_say.sh, config.ini (token).
[from-external]
exten => _X.,1,Goto(s,1)

exten => s,1,NoOp(--- ha_ivr relay ---)
 ; Log what actually arrived. ha_ivr matches the caller on the last 9 digits,
 ; so an empty or wrong CID here is the whole reason a menu filtered by number
 ; answers "the number is not recognised". If CID is empty while the provider
 ; does send one, it is usually in P-Asserted-Identity / Remote-Party-ID, which
 ; PJSIP ignores unless the endpoint sets trust_id_inbound=yes.
 same => n,NoOp(inbound CID=[\${CALLERID(num)}] name=[\${CALLERID(name)}] DID=\${EXTEN})
 same => n,Answer()
 same => n,Set(CHANNEL(language)=he)
 same => n,Set(PBX_GOTO=)
 same => n,Set(PBX_UUID=)
 same => n,AGI(ha_relay.py)
 ; "ha-assist" = assistant via AudioSocket; other = SIP transfer; empty = hangup
 same => n,GotoIf(\$["\${PBX_GOTO}" = "ha-assist"]?assist)
 same => n,GotoIf(\$["\${PBX_GOTO}" != ""]?transfer)
 same => n,Hangup()

 same => n(transfer),Dial(PJSIP/\${PBX_GOTO},30,gH)
 same => n,Hangup()

 ; assistant: stream call audio to ha_ivr. Channel already answered above.
 ; Uses the [globals] target so editing HA_IVR_AUDIOSOCKET + dialplan reload
 ; moves BOTH this path and the probe — one source of truth.
 same => n(assist),AudioSocket(\${PBX_UUID},\${HA_IVR_AUDIOSOCKET})
 same => n,Hangup()

exten => i,1,Hangup()
exten => t,1,Hangup()

; outbound alert dialplan ([ha-outbound] [tts-alerts] [from-ha-alerts]) — P9
#tryinclude "extensions_alerts.conf"
EOF

# agi-bin + HA_IVR relay scripts
mkdir -p /var/lib/asterisk/agi-bin
chown asterisk:asterisk /var/lib/asterisk/agi-bin
# The relay scripts are bundled in the repo (agi-bin/) and are REQUIRED: the
# active [from-external] context runs AGI(ha_relay.py), so a build without them
# answers the call and hangs up with no menu ("File does not exist" in the log).
# Fail loudly rather than install a silently-broken PBX (see verify()).
for f in ha_relay.py edge_say.sh config.ini.sample; do
    [ -f "$SCRIPT_DIR/agi-bin/$f" ] || die "missing bundled agi-bin/$f next to install.sh — extract the full tarball (agi-bin/ included) and re-run from that directory"
done
# refresh the executables every run
install -o asterisk -g asterisk -m 755 "$SCRIPT_DIR/agi-bin/ha_relay.py" /var/lib/asterisk/agi-bin/ha_relay.py
install -o asterisk -g asterisk -m 755 "$SCRIPT_DIR/agi-bin/edge_say.sh" /var/lib/asterisk/agi-bin/edge_say.sh
info "installed ha_relay.py + edge_say.sh"
# config.ini: install the template ONLY if absent — never clobber a real token
if [ ! -f /var/lib/asterisk/agi-bin/config.ini ]; then
    install -o asterisk -g asterisk -m 600 "$SCRIPT_DIR/agi-bin/config.ini.sample" /var/lib/asterisk/agi-bin/config.ini
    info "config.ini template installed — set the token with: sudo ./setup-haivr.py"
else
    info "config.ini already present — left as-is (token preserved)"
fi

# ---------------------------------------------------------------------------
# P9 — outbound alert service: HA (or Uptime Kuma) POSTs a webhook -> call_trigger
# drops a call file -> Asterisk rings the number and speaks the message. Mechanism
# is call files (no AMI/ARI, no management port). See INSTALL.md.
say "P9 — outbound alert service (call-trigger webhook)"
# alert dialplan (contexts [ha-outbound] [tts-alerts] [from-ha-alerts]); pulled in
# by the #tryinclude line written into extensions.conf above.
if [ -f "$SCRIPT_DIR/extensions_alerts.conf" ]; then
    write_cfg /etc/asterisk/extensions_alerts.conf < "$SCRIPT_DIR/extensions_alerts.conf"
    info "installed extensions_alerts.conf"
else
    info "no extensions_alerts.conf next to install.sh — alert dialplan skipped"
fi
# call_trigger.py pre-synthesises every alert via /var/lib/asterisk/agi-bin/
# edge_say.sh (the same helper the AGI relay uses) — no extra TTS path and no
# symlinks are needed for any route, Kuma included.
# Shared alert audio. NOT /tmp: the vendor asterisk.service sets
# PrivateTmp=true, so Asterisk's /tmp is a private namespace and a wav written
# to the real /tmp by call-trigger is invisible to Playback — the call answers
# and drops instantly. Both services can reach this shared path.
mkdir -p /var/lib/asterisk/alert-audio
chown asterisk:asterisk /var/lib/asterisk/alert-audio
chmod 750 /var/lib/asterisk/alert-audio
if [ -f "$SCRIPT_DIR/call_trigger.py" ]; then
    mkdir -p /usr/local/lib/pbx-alert
    install -m 0644 "$SCRIPT_DIR/call_trigger.py" /usr/local/lib/pbx-alert/call_trigger.py
    # env: create with a RANDOM secret only if absent — never clobber a real one.
    # This generated secret is the source of truth: reveal it and paste it into
    # HA's "alert service secret" field so the two match:
    #   sudo grep PBX_ALERT_SECRET /etc/pbx-alert.env
    if [ ! -f /etc/pbx-alert.env ]; then
        secret="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
        {
            printf 'PBX_ALERT_SECRET=%s\n' "$secret"
            printf 'PBX_ALERT_PORT=5000\n'
            printf '# Caller ID for alert calls when the producer sends none, e.g. <0501234567>\n'
            printf 'PBX_ALERT_CALLERID=\n'
        } > /etc/pbx-alert.env
        unset secret   # the end-of-run reveal reads it back from the file
        info "wrote /etc/pbx-alert.env with a random secret — shown at the end"
    else
        info "/etc/pbx-alert.env already present — left as-is (secret preserved)"
    fi
    chown root:root /etc/pbx-alert.env
    chmod 600 /etc/pbx-alert.env
    if [ -f "$SCRIPT_DIR/call-trigger.service" ]; then
        install -m 0644 "$SCRIPT_DIR/call-trigger.service" /etc/systemd/system/call-trigger.service
        systemctl daemon-reload
        systemctl enable call-trigger >/dev/null 2>&1
        info "call-trigger.service installed and enabled"
    fi
else
    info "no call_trigger.py next to install.sh — alert webhook skipped"
fi

# ---------------------------------------------------------------------------
say "starting service"
systemctl restart asterisk
if [ -f /etc/systemd/system/call-trigger.service ]; then
    systemctl restart call-trigger 2>/dev/null \
        && info "call-trigger started" \
        || info "call-trigger not started (set the secret in /etc/pbx-alert.env, then: systemctl restart call-trigger)"
fi

# Wait for a *full* boot before verifying. codec_opus.so is an external binary
# that registers its translator a moment after the core is up, so a fixed sleep
# races the gate (symptom: "Opus translation table empty" on a healthy box).
# Block on the core, then poll until the Opus translator actually appears.
wait_ready() {
    /usr/sbin/asterisk -rx "core waitfullybooted" >/dev/null 2>&1 || true
    local i xlat
    for i in $(seq 1 30); do
        # Capture first, then match on the variable. Piping straight into
        # `grep -q` is a trap under `set -o pipefail`: grep exits at the first
        # match, asterisk gets SIGPIPE (141), pipefail makes that the pipeline
        # status, and the test reads as FALSE even though the match was found.
        # It only bites once the output exceeds the 64K pipe buffer — i.e. when
        # the translation table is POPULATED. The check failed exactly when it
        # should have passed.
        xlat="$(/usr/sbin/asterisk -rx "core show translation" 2>/dev/null || true)"
        if grep -qi opus <<< "$xlat"; then
            info "asterisk fully booted, Opus translator registered (after ${i}s)"
            return 0
        fi
        sleep 1
    done
    info "WARNING: Opus translator not seen after 30s; verify() will report the truth"
    return 0
}
wait_ready

# ---------------------------------------------------------------------------
# verify() — the acceptance gate. Non-zero exit on failure (fail loudly).
verify() {
    say "VERIFY — Opus transcoder gate + AudioSocket"
    local rc=0
    systemctl is-active --quiet asterisk || { echo "FAIL: asterisk not active"; rc=1; }
    # Capture once, match on the variables — never pipe into `grep -q` here.
    # See the note in wait_ready(): pipefail + grep -q's early exit turns a
    # successful match into a false negative as soon as the output is bigger
    # than the pipe buffer.
    local mods xlat
    mods="$(/usr/sbin/asterisk -rx "module show like opus" 2>/dev/null || true)"
    xlat="$(/usr/sbin/asterisk -rx "core show translation" 2>/dev/null || true)"
    if ! grep -q "codec_opus.so" <<< "$mods"; then
        echo "FAIL: codec_opus.so not loaded"; rc=1
    fi
    if ! grep -q "res_format_attr_opus.so" <<< "$mods"; then
        echo "FAIL: res_format_attr_opus.so not loaded"; rc=1
    fi
    if ! grep -qi opus <<< "$xlat"; then
        echo "FAIL: Opus translation table empty"; rc=1
    fi
    local asock
    asock="$(/usr/sbin/asterisk -rx "module show like audiosocket" 2>/dev/null || true)"
    if [ "$(grep -c Running <<< "$asock")" -lt 3 ]; then
        echo "FAIL: AudioSocket modules not all loaded"; rc=1
    fi
    # The HA_IVR relay must be present and executable, or [from-external] answers
    # and hangs up with no menu (res_agi: "File does not exist"). Gate on it.
    if [ ! -x /var/lib/asterisk/agi-bin/ha_relay.py ]; then
        echo "FAIL: /var/lib/asterisk/agi-bin/ha_relay.py missing or not executable"; rc=1
    fi
    # ...and so must its runtime deps, or the relay crashes on the first call
    # while every module check above still passes.
    if ! python3 -c "import asterisk.agi, requests" 2>/dev/null; then
        echo "FAIL: python deps for ha_relay missing (pyst2/requests)"; rc=1
    fi
    command -v edge-tts >/dev/null || { echo "FAIL: edge-tts not installed (TTS path dead)"; rc=1; }
    command -v sox >/dev/null      || { echo "FAIL: sox not installed (TTS path dead)"; rc=1; }
    if [ -f /etc/systemd/system/call-trigger.service ] && [ ! -d /var/lib/asterisk/alert-audio ]; then
        echo "FAIL: /var/lib/asterisk/alert-audio missing — alert calls will drop on answer"; rc=1
    fi
    if [ -f /etc/systemd/system/call-trigger.service ] && ! systemctl is-active --quiet call-trigger; then
        echo "WARN: call-trigger not active (check the secret, then: systemctl restart call-trigger)"
    fi
    # Not a hard gate: a missing rule does not break calls, it just lets the logs
    # grow unbounded over months. Surface it as a warning rather than fail P7.
    if [ ! -f /etc/logrotate.d/asterisk ]; then
        echo "WARN: /etc/logrotate.d/asterisk missing — Asterisk logs will grow unbounded"
    fi
    if [ "$rc" -eq 0 ]; then
        echo "  PASS: codec_opus + res_format_attr_opus loaded, translation table populated,"
        echo "        AudioSocket ready, ha_relay.py + runtime deps installed,"
        echo "        service running as $(ps -o user= -C asterisk | head -1)."
    fi
    return "$rc"
}
verify || die "verification FAILED — see $LOG"

# ---------------------------------------------------------------------------
# security: drop the passwordless-sudo helper if this build created/used one.
# Leaving NOPASSWD in place after an unattended build would be a real weakening,
# so the teardown stays. The glob also catches per-developer names such as
# <user>-pbx-build, without naming anyone in a published installer.
for sudoers_helper in /etc/sudoers.d/*pbx-build; do
    if [ -f "$sudoers_helper" ]; then
        say "removing passwordless-sudo helper ($sudoers_helper)"
        rm -f "$sudoers_helper"
    fi
done

say "DONE — Asterisk ${ASTERISK_VERSION} installed and verified. Log: $LOG"
echo "Next:"
echo "  1. add a provider trunk:   sudo ./setup-trunk.py add     (use a TEST account)"
echo "  2. set the ha_ivr token:   sudo ./setup-haivr.py"
if [ -f /etc/pbx-alert.env ]; then
echo "  3. alert calls: paste this PBX_ALERT_SECRET into HA's 'alert service secret' field."
# Read the value back from the file (works whether generated this run or kept
# from a prior run) and print it to the TERMINAL only — never stdout, which is
# tee'd into $LOG (rule: never log a secret). The grep line always prints too,
# so the operator is never left without a way to retrieve it (no-tty runs).
_sec="$(sed -n 's/^PBX_ALERT_SECRET=//p' /etc/pbx-alert.env 2>/dev/null || true)"
if [ -n "${_sec:-}" ]; then
    if ! { printf '\n     PBX_ALERT_SECRET = %s\n\n' "$_sec" >/dev/tty; } 2>/dev/null; then
        echo "     (no terminal attached — use the command below to read it)"
    fi
fi
unset _sec
echo "     retrieve anytime:  sudo grep PBX_ALERT_SECRET /etc/pbx-alert.env"
echo "     optional: set PBX_ALERT_CALLERID=<your-number> in /etc/pbx-alert.env,"
echo "     then: systemctl restart call-trigger   (default caller ID on alerts)"
fi
