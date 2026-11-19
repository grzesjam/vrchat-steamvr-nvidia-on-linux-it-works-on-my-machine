#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -t 1 ]]; then
    C_RESET=$'\e[0m' C_DIM=$'\e[2m' C_INFO=$'\e[36m' C_OK=$'\e[32m'
    C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_DEBUG=$'\e[35m' C_CMD=$'\e[34m'
else
    C_RESET='' C_DIM='' C_INFO='' C_OK='' C_WARN='' C_ERR='' C_DEBUG='' C_CMD=''
fi
_log() { printf '%s[%s]%s %s%-5s%s %s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RESET" "$1" "$2" "$C_RESET" "$3"; }
info()  { _log "$C_INFO"  INFO  "$*"; }
ok()    { _log "$C_OK"    OK    "$*"; }
warn()  { _log "$C_WARN"  WARN  "$*" >&2; }
err()   { _log "$C_ERR"   ERROR "$*" >&2; }
debug() { _log "$C_DEBUG" DEBUG "$*"; }
# Run a command, print it and its output (indented), report the exit code.
run() {
    local out rc=0
    _log "$C_CMD" CMD "\$ $*"
    out=$("$@" 2>&1) || rc=$?
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed "s/^/        ${C_DIM}│${C_RESET} /"
    if [[ $rc -eq 0 ]]; then ok "command succeeded (exit 0)"; else err "command failed (exit $rc)"; fi
    return $rc
}

command -v sudo >/dev/null || { err 'sudo not found'; exit 1; }
command -v iw >/dev/null || { err 'iw not found'; exit 1; }

CLOCK_SCRIPT="$HERE/nvidia-clock.sh"
[[ -f "$CLOCK_SCRIPT" ]] || { err "Missing $CLOCK_SCRIPT"; exit 1; }
command -v steam >/dev/null || { err 'Steam not found'; exit 1; }
command -v python3 >/dev/null || { err 'python3 not found'; exit 1; }
command -v pgrep >/dev/null || { err 'pgrep not found'; exit 1; }

TOGGLES="$HERE/holo-realtek-firmware-toggles"
HOLO_SOURCES="https://steamdeck-packages.steamos.cloud/archlinux-mirror/sources/holo-3.10"
# Valve's script is MIT licensed and not shipped in this repo; fetch the newest one on first run.
fetch_toggles() {
    command -v curl >/dev/null || { err "curl not found; download holo-realtek-firmware-toggles manually (see README)"; return 1; }
    local tmp pkg
    tmp=$(mktemp -d) || return 1
    pkg=$(curl -fsSL "$HOLO_SOURCES/" | grep -o 'holo-realtek-firmware-toggles-[0-9][^"<]*\.src\.tar\.gz' | sort -uV | tail -1)
    pkg=${pkg:-holo-realtek-firmware-toggles-1.4-1.src.tar.gz}
    info "Downloading $pkg from $HOLO_SOURCES ..."
    if curl -fsSL -o "$tmp/$pkg" "$HOLO_SOURCES/$pkg" \
        && tar xzf "$tmp/$pkg" -C "$tmp" \
        && install -m 755 "$tmp/holo-realtek-firmware-toggles/holo-realtek-firmware-toggles" "$TOGGLES"; then
        cat > "$TOGGLES.LICENSE" <<EOF
holo-realtek-firmware-toggles is (c) Valve Corporation, licensed under the MIT License
(license=('MIT') in its PKGBUILD). It is not part of this repository's WTFPL code.
Source: $HOLO_SOURCES/$pkg
EOF
        ok "Installed $TOGGLES (MIT License, (c) Valve Corporation; see $TOGGLES.LICENSE)"
    else
        err "Download failed; get it manually (see README)"
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
}
[[ -x "$TOGGLES" ]] || fetch_toggles || exit 1

info 'Authenticate for Wi-Fi regulatory domain, low-latency mode and NVIDIA clock TUI:'
sudo -v || exit 1
ok 'sudo authenticated.'

info 'Setting Wi-Fi regulatory domain to US...'
run sudo -n iw reg set US || { err 'Failed to set Wi-Fi regulatory domain to US'; exit 1; }

reset_low_latency() {
    info 'Resetting Realtek low-latency mode...'
    run sudo -n env PATH="$PATH" "$TOGGLES" reset \
        || warn 'Failed to reset low-latency mode.'
}
reset_low_latency

# Keep sudo credentials alive for the whole session so later sudo calls
# (including the one inside nvidia-clock.sh) don't prompt again.
SUDO_KEEPALIVE_PID=""
LOW_LATENCY_PID=""
MAIN_PID=$$
(
    while kill -0 "$MAIN_PID" 2>/dev/null; do
        sudo -n -v >/dev/null 2>&1 || { warn 'sudo keepalive failed; later sudo calls may fail.'; exit; }
        sleep 50
    done
) &
SUDO_KEEPALIVE_PID=$!
debug "sudo keepalive running (PID $SUDO_KEEPALIVE_PID)"
CLEANED_UP=0
cleanup() {
    [[ "$CLEANED_UP" == 1 ]] && return
    CLEANED_UP=1
    info 'Cleaning up...'
    [[ -n "$LOW_LATENCY_PID" ]] && kill "$LOW_LATENCY_PID" 2>/dev/null || true
    reset_low_latency
    [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    ok 'Cleanup done.'
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Prints "IFACE: SSID" if any interface is associated to (managed) or hosting
# (AP mode, e.g. the Steam Frame dongle) a network whose name contains "frame".
find_frame_link() {
    local iface ssid type
    while read -r iface type ssid; do
        [[ -n "$iface" ]] || continue
        if [[ "$type" == AP* && "${ssid,,}" == *frame* ]]; then
            echo "$iface: $ssid (hosted, $type)"
            return 0
        fi
        ssid=$(iw dev "$iface" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p')
        if [[ "${ssid,,}" == *frame* ]]; then
            echo "$iface: $ssid (connected)"
            return 0
        fi
    done < <(iw dev | awk '
        $1 == "Interface" { if (i != "") print i, t, s; i = $2; t = "-"; s = "" }
        $1 == "type" { t = $2 }
        $1 == "ssid" { $1 = ""; sub(/^ /, ""); s = $0 }
        END { if (i != "") print i, t, s }')
    return 1
}

VRSERVER_WAIT=30
(
    while true; do
        info 'Waiting for a Wi-Fi link whose name contains "Frame"...'
        FRAME_LINK_COUNT=0
        LAST_STATUS=""
        while true; do
            if LINK=$(find_frame_link); then
                FRAME_LINK_COUNT=$((FRAME_LINK_COUNT + 1))
                debug "Frame Wi-Fi link detected ($LINK), stable check $FRAME_LINK_COUNT/3"
                if [[ "$FRAME_LINK_COUNT" -ge 3 ]]; then
                    ok 'Frame Wi-Fi link is stable.'
                    break
                fi
            else
                [[ "$FRAME_LINK_COUNT" -gt 0 ]] && warn 'Frame Wi-Fi link lost; restarting stability check.'
                FRAME_LINK_COUNT=0
                STATUS=$(iw dev | awk '$1 == "Interface" {i=$2} $1 == "type" {printf "%s(%s) ", i, $2}')
                if [[ "$STATUS" != "$LAST_STATUS" ]]; then
                    debug "No Frame link yet. Interfaces: ${STATUS:-none}"
                    LAST_STATUS=$STATUS
                fi
            fi
            sleep 2
        done

        info "Waiting for SteamVR (vrserver) to run continuously for ${VRSERVER_WAIT} seconds..."
        VRSERVER_SINCE=0
        LINK_OK=1
        while true; do
            if ! find_frame_link >/dev/null; then
                warn 'Frame Wi-Fi link lost while waiting for SteamVR; waiting for it again.'
                LINK_OK=0
                break
            fi
            if VRPID=$(pgrep -u "$(id -u)" -x vrserver); then
                if [[ "$VRSERVER_SINCE" -eq 0 ]]; then
                    VRSERVER_SINCE=$(date +%s)
                    info "SteamVR detected (PID ${VRPID//$'\n'/ }); starting ${VRSERVER_WAIT}-second timer."
                fi
                NOW=$(date +%s)
                if (( NOW - VRSERVER_SINCE >= VRSERVER_WAIT )); then
                    ok "SteamVR has been running for ${VRSERVER_WAIT} seconds; enabling low-latency mode."
                    if run sudo -n env PATH="$PATH" "$TOGGLES" set-low-latency-mode on; then
                        ok 'Low-latency mode enabled. Current state:'
                        run sudo -n env PATH="$PATH" "$TOGGLES" list || true
                    else
                        err 'Failed to enable low-latency mode.'
                    fi
                    break
                fi
            else
                if [[ "$VRSERVER_SINCE" -ne 0 ]]; then
                    warn "SteamVR stopped before ${VRSERVER_WAIT} seconds; restarting timer."
                fi
                VRSERVER_SINCE=0
            fi
            sleep 2
        done
        [[ "$LINK_OK" == 1 ]] || continue

        # Watch the link; on loss, reset the dongle and start over so the
        # low-latency settings get reapplied once the link comes back.
        while find_frame_link >/dev/null; do
            sleep 2
        done
        warn 'Frame Wi-Fi link lost; resetting dongle.'
        reset_low_latency
    done
) &
LOW_LATENCY_PID=$!
debug "Low-latency watcher running (PID $LOW_LATENCY_PID)"

# read -r -p 'Launch optional Steam app 438100 (VRChat)? [y/N]: ' ANSWER
# case "$ANSWER" in y|Y|yes|YES|Yes) OPTIONAL=1 ;; *) OPTIONAL=0 ;; esac
OPTIONAL=0
info "Starting session watchdog (launch VRChat: $([[ $OPTIONAL == 1 ]] && echo yes || echo no))"
# Not exec: the shell must stay alive so the exit trap can reset low-latency mode.
python3 "$HERE/session-watchdog.py" "$OPTIONAL" "$HERE" || true
