#!/bin/bash
# פותר בעיות נתיבים של שירותי רקע
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# תעודות CA (עוקף חסימות של מסנני רשת עבור מנוע ה-Edge)
export REQUESTS_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
export WEBSOCKET_CLIENT_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

TEXT="$1"
# $2 is either a bare name (kept under /tmp, the historic behaviour) or a path
# containing "/", used as-is. Files shared with the Asterisk process must NOT
# live in /tmp: asterisk.service runs with PrivateTmp=true, so its /tmp is a
# private namespace and anything another service writes to the real /tmp is
# invisible to Playback.
case "$2" in
    */*) FILENAME="$2" ;;
    *)   FILENAME="/tmp/$2" ;;
esac
# $$ keeps concurrent invocations from clobbering each other's intermediates;
# the final wav appears atomically via mv, so a caller that cache-checks the
# final path can never observe a half-written file.
RAW_FILE="${FILENAME}_raw.$$.mp3"
TMP_WAV="${FILENAME}.$$.tmp.wav"
FINAL_FILE="${FILENAME}.wav"
LOG_FILE="/tmp/edge_error.log"

# cap the shared error log at ~1MB so it cannot creep up between reboots
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
        echo "ERROR: sox produced no output for ${FILENAME}." >> "$LOG_FILE"
        rm -f "$TMP_WAV"
        exit 1
    fi
else
    echo "ERROR: File was not created. Edge-TTS failed." >> "$LOG_FILE"
    rm -f "$RAW_FILE"
    exit 1
fi
