#!/system/bin/sh
# Thor Wi-Fi auto-connect — single-file script.
#
# Runs at boot via Magisk service.d. With no saved config it re-invokes itself
# in setup mode, which prompts for the network name and password. At boot there
# is no terminal, so setup cannot prompt and posts a notification instead.
#
# Usage:
#   At boot:    installed in /data/adb/service.d/, runs automatically
#   Manually:   adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh'"
#   Reconfig:   adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --setup'"
#   Re-pick AP: adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --rediscover'"
#   Debug:      adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --log'"
#   Version:    adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --version'"
#   Uninstall:  adb shell "su -c 'sh /data/adb/service.d/thor-wifi.sh --uninstall'"
#
# --setup asks which band to prefer (5 GHz by default). The choice is saved in
# the config and used by --rediscover and at boot.
#
# Logging is OFF by default: a normal boot writes nothing to disk. Turn it on
# with --log, off with --no-log. The status file is always written — one line,
# and how you check the result without a log.
#
# Why this exists:
#   Android's paired WPA2/WPA3 auto-upgrade creates a malformed WPA3 profile
#   for mixed-mode SSIDs. Network selection picks it and the SAE handshake
#   times out. Pinning the BSSID with `-b` forces a single clean profile.
#
#   `-r auto` uses a randomized MAC. The access point blacklists a client MAC
#   after repeated failed association attempts, so a stable factory MAC
#   eventually stops working. Android stores the randomized MAC per-network,
#   so it persists across reboots.
#
# See docs/WIFI-SCRIPT.md for the full explanation.
#
# Code written with AI Assistance from DeepSeek.

# Bump on every change. `--version` prints it. Keep MAJOR.MINOR.PATCH.
VERSION="1.0.0"

DIR="/data/local/thor-wifi"
CONF="$DIR/config"
CRED="$DIR/cred"
LOG="/data/local/tmp/thor-wifi-boot.log"
STATUS="/data/local/tmp/thor-wifi-boot.status"
SELF="/data/adb/service.d/thor-wifi.sh"
STAGING="/data/local/tmp/thor-wifi.sh"

KEEP_DAYS=7
LOGGING=0

# ========================================================================
# Primitives
# ========================================================================

# No-op when logging is off, so call sites stay unconditional.
log() {
    [ "$LOGGING" = "1" ] || return 0
    # umask would leave the log 644; create it 600 on first write.
    [ -f "$LOG" ] || { (umask 077; : > "$LOG"); chown 0:0 "$LOG" 2>/dev/null; }
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

set_status() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" > "$STATUS"; }

notify() { cmd notification post -S bigtext -t "Thor Wi-Fi" thorwifi "$1" >/dev/null 2>&1; }

# Write a value to a settings file under $DIR, 600 root:root.
save_setting() {
    mkdir -p "$DIR"
    printf %s "$2" > "$DIR/$1"
    chmod 600 "$DIR/$1"
    chown 0:0 "$DIR/$1" 2>/dev/null
}

# Echo a saved setting, or nothing if absent or not a plain integer.
load_setting() {
    [ -f "$DIR/$1" ] || return 0
    V=$(cat "$DIR/$1" 2>/dev/null)
    case "$V" in ''|*[!0-9]*) return 0 ;; esac
    echo "$V"
}

# BSSID the device is currently associated with, or empty.
current_bssid() {
    cmd wifi status 2>/dev/null | grep -o 'BSSID: [0-9a-f:]*' | head -1 | cut -d' ' -f2
}

# Poll until the device is on $1. Returns 0 on success, 1 after 60s.
wait_for_bssid() {
    i=0
    while [ $i -lt 30 ]; do
        [ "$(current_bssid)" = "$1" ] && return 0
        sleep 2
        i=$((i + 1))
    done
    return 1
}

# Drop log lines older than KEEP_DAYS. Runs at the start of every boot.
# toybox date rejects relative dates ("-7 days") but accepts @EPOCH.
rotate_log() {
    [ -f "$LOG" ] || return 0
    [ "$KEEP_DAYS" -gt 0 ] 2>/dev/null || return 0

    NOW=$(date '+%s' 2>/dev/null)
    [ -z "$NOW" ] && return 0
    CUTOFF=$(date -d "@$((NOW - KEEP_DAYS * 86400))" '+%Y-%m-%d' 2>/dev/null)
    [ -z "$CUTOFF" ] && return 0

    awk -v cutoff="$CUTOFF" 'substr($0, 1, 10) >= cutoff' "$LOG" > "$LOG.tmp" 2>/dev/null \
        && mv "$LOG.tmp" "$LOG"
    chmod 600 "$LOG" 2>/dev/null
}

# ========================================================================
# AP discovery — shared by setup and rediscover
# ========================================================================

# Scan for $SSID and set PICK / PICK_DESC / NORM.
# Never picks SAE — that is the bug being worked around. Within the chosen
# band, strongest signal wins. BAND is "5" (default) or "2.4".
# Sets NO_WPA2=1 when no WPA2 AP exists. Returns 1 if the SSID is not in range.
discover_ap() {
    cmd wifi start-scan >/dev/null 2>&1
    sleep 6

    # Columns: BSSID  freq  signal  age  SSID  flags
    # Signal looks like "-62(0:-91/1:-62)"; take the first number.
    RESULTS=$(cmd wifi list-scan-results 2>/dev/null | grep -F "$SSID")
    [ -z "$RESULTS" ] && return 1

    # rssi bssid freq flags, strongest first, so the first match wins.
    NORM=$(echo "$RESULTS" | awk '{
        rssi = $3; sub(/\(.*/, "", rssi)
        printf "%s %s %s %s\n", rssi, $1, $2, $NF
    }' | sort -rn)

    PICK=""
    PICK_DESC=""
    NO_WPA2=0

    pick_ap() { PICK=$(echo "$NORM" | awk "$1" | head -1); }

    # Preferred band first, then the other band, then any WPA2, then anything.
    if [ "$BAND" = "2.4" ]; then
        pick_ap '$3 >= 2400 && $3 <= 2500 && /WPA2/ {print $2}'
        [ -n "$PICK" ] && PICK_DESC="2.4 GHz WPA2"
        if [ -z "$PICK" ]; then
            pick_ap '$3 >= 5000 && $3 <= 5895 && /WPA2/ {print $2}'
            [ -n "$PICK" ] && PICK_DESC="5 GHz WPA2 (2.4 GHz not available)"
        fi
    else
        pick_ap '$3 >= 5000 && $3 <= 5895 && /WPA2/ {print $2}'
        [ -n "$PICK" ] && PICK_DESC="5 GHz WPA2"
        if [ -z "$PICK" ]; then
            pick_ap '$3 >= 2400 && $3 <= 2500 && /WPA2/ {print $2}'
            [ -n "$PICK" ] && PICK_DESC="2.4 GHz WPA2 (5 GHz not available)"
        fi
    fi

    if [ -z "$PICK" ]; then
        pick_ap '/WPA2/ {print $2}'
        [ -n "$PICK" ] && PICK_DESC="WPA2"
    fi

    if [ -z "$PICK" ]; then
        pick_ap '{print $2}'
        PICK_DESC="unknown security"
        NO_WPA2=1
    fi

    return 0
}

# Print the scan table and the selection. Shared by setup and rediscover.
show_aps() {
    echo ""
    echo "Found these access points (strongest first):"
    echo "$NORM" | awk '{printf "  %s  %6s MHz  %s dBm  %s\n", $2, $3, $1, $4}'
    echo ""
    echo "Selected: $PICK ($PICK_DESC)"
}

# Warn when only SAE is available. Shared by setup and rediscover.
warn_no_wpa2() {
    [ "$NO_WPA2" = "1" ] || return 0
    echo ""
    echo "WARNING: no WPA2 access point found for this SSID."
    echo "Only SAE is available, which is the configuration that fails."
    echo "The fix may not work."
}

# Scan for $SSID, or print an error and exit. Shared by setup and rediscover.
scan_or_die() {
    echo ""
    echo "Scanning for \"$SSID\"..."
    if ! discover_ap; then
        echo ""
        echo "Could not find \"$SSID\" in scan results."
        echo "Make sure the network is in range and try again."
        exit 1
    fi
    warn_no_wpa2
    show_aps
}

# ========================================================================
# Connect
# ========================================================================

# Connect to $SSID pinned to $BSSID using $PASSWORD.
# Output is discarded, never logged: the command does not echo its arguments
# today, but redirecting it into the log would put the password there if that
# ever changed.
connect() {
    cmd wifi connect-network "$SSID" "$AUTH" "$PASSWORD" -b "$BSSID" -r "$MAC_MODE" >/dev/null 2>&1
}

# Work out why the last attempt failed, so the message names the real cause.
# A wrong password and a MAC block look identical from the outside, but the
# supplicant records which one it was. Prints a hint, or nothing if unknown.
diagnose_failure() {
    local dump
    dump=$(dumpsys wifi 2>/dev/null)

    if echo "$dump" | grep -q "ERROR_AUTH_FAILURE_WRONG_PSWD"; then
        echo "The password was rejected (ERROR_AUTH_FAILURE_WRONG_PSWD)."
        echo "Re-run with --setup and check the password."
    elif echo "$dump" | grep -q "AUTHENTICATION_FAILURE_EVENT"; then
        echo "Authentication failed. The password may be wrong, or the access"
        echo "point may be rejecting this device."
    else
        echo "The access point may have blacklisted this device's MAC."
        echo "Reboot the router, then run this again."
    fi
}

# Connect and report. Returns 0 on success.
test_connection() {
    echo ""
    echo "Testing connection..."
    connect
    if wait_for_bssid "$BSSID"; then
        echo ""
        echo "SUCCESS — connected to $BSSID"
        return 0
    fi
    echo ""
    echo "FAILED — could not connect to $BSSID"
    echo ""
    diagnose_failure
    return 1
}

# ========================================================================
# Setup mode — prompts for credentials, discovers the AP, writes config
# ========================================================================
do_setup() {
    echo ""
    echo "=== Thor Wi-Fi setup ==="
    echo ""

    printf "Network name (SSID): "
    read SSID
    [ -z "$SSID" ] && { echo "No SSID given. Aborting."; exit 1; }

    printf "Password: "
    stty -echo 2>/dev/null
    read PASS
    stty echo 2>/dev/null
    echo ""
    [ -z "$PASS" ] && { echo "No password given. Aborting."; exit 1; }

    # 5 GHz is the default: same throughput as 2.4 GHz, far less congestion.
    echo ""
    echo "Which band should this prefer?"
    echo "  1) 5 GHz  (default — faster, less congested)"
    echo "  2) 2.4 GHz (longer range, slower)"
    printf "Choice [1]: "
    read BAND_CHOICE
    case "$BAND_CHOICE" in
        2) BAND="2.4" ;;
        *) BAND="5" ;;
    esac

    scan_or_die

    mkdir -p "$DIR"
    chmod 700 "$DIR"

    cat > "$CONF" <<EOF
SSID="$SSID"
BSSID="$PICK"
AUTH="wpa2"
MAC_MODE="auto"
BAND="$BAND"
EOF

    printf %s "$PASS" > "$CRED"
    chmod 600 "$CONF" "$CRED"
    chown 0:0 "$CONF" "$CRED" 2>/dev/null

    echo ""
    echo "Wrote $CONF"
    echo "Wrote $CRED"

    BSSID="$PICK"
    AUTH="wpa2"
    MAC_MODE="auto"
    PASSWORD="$PASS"

    if test_connection; then
        echo ""
        echo "This will now run automatically on every boot."
    fi
    echo ""
    exit 0
}

# ========================================================================
# Rediscover mode — re-pick the AP without re-entering the password
# ========================================================================
# Mesh systems rotate BSSIDs on reboot and expose many per SSID, so a pinned
# BSSID goes stale. Re-runs discovery against the saved SSID and rewrites only
# the BSSID line, leaving the credential file untouched.
do_rediscover() {
    echo ""
    echo "=== Thor Wi-Fi rediscover ==="
    echo ""

    if [ ! -f "$CONF" ]; then
        echo "No saved config at $CONF."
        echo "Run --setup first."
        exit 1
    fi

    . "$CONF"
    [ -z "$SSID" ] && { echo "Saved config has no SSID. Run --setup."; exit 1; }
    # Configs written before BAND existed default to 5 GHz.
    [ -z "$BAND" ] && BAND="5"

    echo "Saved network: $SSID"
    echo "Saved BSSID:   ${BSSID:-none}"
    echo "Saved band:    $BAND GHz"

    scan_or_die

    if [ "$PICK" = "$BSSID" ]; then
        echo ""
        echo "Same as the saved BSSID. Nothing to change."
        echo ""
        exit 0
    fi

    # Rewrite only the BSSID line, so this never needs the password.
    awk -v bssid="$PICK" '
        /^BSSID=/ { print "BSSID=\"" bssid "\""; next }
        { print }
    ' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    chmod 600 "$CONF"
    chown 0:0 "$CONF" 2>/dev/null

    echo ""
    echo "Updated $CONF"

    if [ ! -f "$CRED" ]; then
        echo ""
        echo "No credential file at $CRED — cannot test the connection."
        echo "Run --setup to enter the password."
        exit 1
    fi

    BSSID="$PICK"
    PASSWORD=$(cat "$CRED")
    test_connection
    echo ""
    exit 0
}

# ========================================================================
# Version
# ========================================================================
do_version() {
    echo "thor-wifi.sh $VERSION"
    echo "Code written with AI Assistance from DeepSeek."
}

# ========================================================================
# Uninstall — removes everything this script creates
# ========================================================================
# Options:
#   --forget    Also forget the saved Wi-Fi network, so Android drops the
#               stored password. The SSID is read from the config first.
#   --dry-run   List what would be removed and exit without changing anything.
#   --yes       Skip the confirmation prompt. For scripted use.
#
# The script deletes itself last. `rm` on a running script is safe on Linux —
# the inode stays alive until the shell exits.
do_uninstall() {
    UN_FORGET=0
    UN_DRY_RUN=0
    UN_YES=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --forget)  UN_FORGET=1 ;;
            --dry-run) UN_DRY_RUN=1 ;;
            --yes)     UN_YES=1 ;;
            *)
                echo "Unknown uninstall option: $1"
                echo "Usage: thor-wifi.sh --uninstall [--forget] [--dry-run] [--yes]"
                exit 1
                ;;
        esac
        shift
    done

    # Read the SSID before anything is deleted. Only needed for --forget.
    UN_SSID=""
    [ -f "$CONF" ] && UN_SSID=$(grep -E '^SSID=' "$CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

    # path|description, one per line. Staging copies are left by `adb push`.
    # mksh reads a bare `|` inside ${var%%...} as a pipe and expands to empty,
    # so the delimiter must be escaped as \| here.
    TARGETS=""
    for entry in \
        "$SELF|boot script (this file)" \
        "$DIR|config directory (SSID, BSSID, password, settings)" \
        "$LOG|log file" \
        "$STATUS|status file" \
        "$STAGING|staging copy"
    do
        [ -e "${entry%%\|*}" ] && TARGETS="$TARGETS$entry
"
    done

    echo ""
    echo "=== Thor Wi-Fi uninstall ==="
    echo ""

    if [ -z "$TARGETS" ]; then
        echo "Nothing to remove. No files from thor-wifi.sh were found."
        echo ""
        exit 0
    fi

    echo "The following will be removed:"
    echo ""
    echo "$TARGETS" | while IFS='|' read -r path desc; do
        [ -n "$path" ] && printf "  %-46s %s\n" "$path" "$desc"
    done
    echo ""

    if [ "$UN_FORGET" = "1" ]; then
        if [ -n "$UN_SSID" ]; then
            echo "The saved Wi-Fi network \"$UN_SSID\" will also be forgotten."
            echo "Android will drop its stored copy of the password."
        else
            echo "WARNING: --forget was given but no SSID could be read from"
            echo "$CONF. The network will NOT be forgotten."
        fi
        echo ""
    else
        echo "Your saved Wi-Fi network is left alone. Android keeps its own copy"
        echo "of the password and the device stays connected. Use --forget to"
        echo "remove that too."
        echo ""
    fi

    if [ "$UN_DRY_RUN" = "1" ]; then
        echo "Dry run — nothing was changed."
        echo ""
        exit 0
    fi

    if [ "$UN_YES" != "1" ]; then
        if [ -t 0 ]; then
            printf "Proceed? [y/N] "
            read ANSWER
            case "$ANSWER" in
                y|Y|yes|YES) ;;
                *) echo "Aborted. Nothing was changed."; echo ""; exit 0 ;;
            esac
        else
            echo "No terminal to confirm on. Re-run with --yes to proceed."
            echo "Nothing was changed."
            echo ""
            exit 1
        fi
    fi

    echo ""
    echo "Removing..."

    # Forget the network first, while the config still exists.
    if [ "$UN_FORGET" = "1" ] && [ -n "$UN_SSID" ]; then
        # `cmd wifi list-networks` prints a header then one row per saved
        # network, with the SSID unquoted:
        #
        #   Network Id      SSID                         Security type
        #   0            MyNetwork                        wpa2-psk
        #   0            MyNetwork                        wpa3-sae^
        #
        # A mixed-mode SSID appears twice, once per security type, both under
        # the same id. Collect every id so no profile is left holding the
        # password.
        NET_IDS=$(cmd wifi list-networks 2>/dev/null \
            | awk -v ssid="$UN_SSID" '
                NR == 1 { next }                       # skip the header row
                {
                    id = $1
                    $1 = ""                            # drop the id column
                    sub(/^[ \t]+/, "")                 # trim leading space
                    sub(/[ \t]+[^ \t]+[ \t]*$/, "")    # drop the trailing security type
                    if ($0 == ssid) print id
                }' \
            | sort -u)

        if [ -n "$NET_IDS" ]; then
            for id in $NET_IDS; do
                if cmd wifi forget-network "$id" >/dev/null 2>&1; then
                    echo "  forgot network \"$UN_SSID\" (id $id)"
                else
                    echo "  WARNING: could not forget network \"$UN_SSID\" (id $id)"
                fi
            done
        else
            echo "  WARNING: \"$UN_SSID\" not found in saved networks, nothing to forget"
        fi
    fi

    # The config directory holds the password, so it goes first.
    if [ -d "$DIR" ]; then
        rm -rf "$DIR" && echo "  removed $DIR" || echo "  WARNING: could not remove $DIR"
    fi

    for f in "$LOG" "$STATUS" "$STAGING"; do
        [ -e "$f" ] && rm -f "$f" && echo "  removed $f"
    done

    echo ""
    LEFT=""
    for p in "$DIR" "$LOG" "$STATUS" "$STAGING"; do
        [ -e "$p" ] && LEFT="$LEFT$p
"
    done

    if [ -n "$LEFT" ]; then
        echo "Some files could not be removed:"
        echo "$LEFT" | while read -r p; do [ -n "$p" ] && echo "  $p"; done
        echo ""
        echo "Check that you are running as root."
    else
        echo "Done. Everything was removed."
        echo ""
        echo "The boot script is gone, so nothing will run on the next boot."
        echo "Reboot to confirm, or just carry on — there is no service to stop."
    fi
    echo ""

    # Last, so the shell has finished reading this file.
    [ -e "$SELF" ] && rm -f "$SELF" 2>/dev/null

    exit 0
}

# ========================================================================
# Options
# ========================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        --setup)      do_setup ;;
        --rediscover) do_rediscover ;;
        --version)    do_version; exit 0 ;;
        --uninstall)  shift; do_uninstall "$@" ;;
        --keep-days)
            KEEP_DAYS="$2"
            case "$KEEP_DAYS" in
                ''|*[!0-9]*)
                    echo "Usage: --keep-days N   (N is a whole number of days)"
                    exit 1
                    ;;
            esac
            save_setting keep-days "$KEEP_DAYS"
            echo "Log retention set to $KEEP_DAYS days."
            LOGGING=1
            rotate_log
            echo "Log rotated."
            exit 0
            ;;
        --log)
            save_setting logging 1
            echo "Logging enabled. It will run on every boot until --no-log."
            echo "Log: $LOG"
            exit 0
            ;;
        --no-log)
            save_setting logging 0
            rm -f "$LOG"
            echo "Logging disabled and log removed."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: thor-wifi.sh [--setup] [--rediscover] [--log] [--no-log] [--keep-days N]"
            echo "       thor-wifi.sh --version"
            echo "       thor-wifi.sh --uninstall [--forget] [--dry-run] [--yes]"
            exit 1
            ;;
    esac
done

# Saved settings override the defaults. Absent logging means off.
SAVED=$(load_setting keep-days)
[ -n "$SAVED" ] && KEEP_DAYS="$SAVED"
[ "$(load_setting logging)" = "1" ] && LOGGING=1

# No config yet. If we have a terminal, prompt. If not (boot), notify.
if [ ! -f "$CONF" ]; then
    if [ -t 0 ]; then
        do_setup
    else
        log "no config at $CONF and no terminal"
        set_status "SKIPPED: not configured"
        notify "Wi-Fi not configured. Run: adb shell \"su -c 'sh /data/adb/service.d/thor-wifi.sh --setup'\""
        exit 0
    fi
fi

# ========================================================================
# Boot mode
# ========================================================================

# --- Wait for boot ------------------------------------------------------
i=0
while [ $i -lt 60 ]; do
    [ "$(getprop sys.boot_completed)" = "1" ] && break
    sleep 2
    i=$((i + 1))
done

if [ "$(getprop sys.boot_completed)" != "1" ]; then
    log "boot_completed never set, aborting"
    set_status "FAILED: boot never completed"
    exit 1
fi

[ "$LOGGING" = "1" ] && rotate_log
log "--- boot script start ---"
log "boot completed after $((i * 2))s"

# Give the Wi-Fi stack time to initialise and complete its own scan.
sleep 20

# --- Load config --------------------------------------------------------
. "$CONF"

# Configs written before BAND existed default to 5 GHz.
[ -z "$BAND" ] && BAND="5"

if [ -z "$SSID" ] || [ -z "$BSSID" ]; then
    log "config incomplete: SSID='$SSID' BSSID='$BSSID'"
    set_status "SKIPPED: config incomplete"
    notify "Wi-Fi config is incomplete. Re-run with --setup."
    exit 0
fi

if [ ! -f "$CRED" ]; then
    log "no credential file at $CRED"
    set_status "SKIPPED: no credential"
    notify "Wi-Fi password missing. Re-run with --setup."
    exit 0
fi

# --- Wi-Fi enabled? -----------------------------------------------------
if ! cmd wifi status 2>/dev/null | grep -q "Wifi is enabled"; then
    log "wifi not enabled, aborting"
    set_status "SKIPPED: wifi disabled"
    exit 0
fi

# --- In range? If not, we are away from home. Stay quiet. ---------------
if ! cmd wifi list-scan-results 2>/dev/null | grep -qF "$SSID"; then
    log "$SSID not in scan results, away from home, doing nothing"
    set_status "SKIPPED: $SSID not in range"
    exit 0
fi

log "$SSID is in range"

# --- Already on the target BSSID? ---------------------------------------
CURRENT=$(current_bssid)
if [ "$CURRENT" = "$BSSID" ]; then
    log "already connected to $BSSID, nothing to do"
    set_status "OK: already on target AP"
    exit 0
fi

log "current BSSID: ${CURRENT:-none}, target: $BSSID"

# --- Connect ------------------------------------------------------------
PASSWORD=$(cat "$CRED")
if [ -z "$PASSWORD" ]; then
    log "credential file empty, aborting"
    set_status "FAILED: credential file empty"
    notify "Wi-Fi password file is empty. Re-run with --setup."
    exit 1
fi

log "connecting to $SSID pinned to $BSSID"
connect

# Verify by BSSID, not supplicant state: if the device is already connected to
# a different AP, the state is COMPLETED from the first check and the loop
# would report false success without ever moving to the target AP.
if wait_for_bssid "$BSSID"; then
    log "connected to target BSSID $BSSID"
    set_status "OK: connected to $BSSID"
    exit 0
fi

# --- Failed -------------------------------------------------------------
NEW=$(current_bssid)
STATE=$(cmd wifi status 2>/dev/null | grep -o 'Supplicant state: [A-Z]*' | head -1 | cut -d' ' -f3)
log "timed out waiting for target BSSID (last BSSID: ${NEW:-none}, state: ${STATE:-unknown})"
set_status "FAILED: still on ${NEW:-no AP} after 60s (state: ${STATE:-unknown})"

# Name the likely cause in the notification too, not just the console.
if dumpsys wifi 2>/dev/null | grep -q "ERROR_AUTH_FAILURE_WRONG_PSWD"; then
    notify "Could not connect to $SSID: the password was rejected. Re-run with --setup."
else
    notify "Could not connect to $SSID. The router may have blocked this device. Check $LOG"
fi
exit 1
