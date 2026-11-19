#!/usr/bin/env bash

set -u

GPU="${GPU:-0}"
POLL_SECONDS="${POLL_SECONDS:-2}"
FORCE_DOWNCLOCK="${FORCE_DOWNCLOCK:-0}"
PROFILE=3
MODE="preset"
CONTROL_MODE="preset"
CUSTOM_CORE=1200
CUSTOM_MEM=810
LIMITED=0
LAST_GAME_STATE=-1
LAST_LOGGED_STATE=-1
MESSAGE="Starting"
MAIN_PID=$$
SUDO_KEEPALIVE_PID=""

declare -a PROFILE_NAMES=("Very low" "Low" "Medium-low" "Balanced" "High" "Very high" "Extreme" "Ultra" "Maximum")
# Core targets as a percentage of the GPU's highest supported core clock.
declare -a CORE_PERCENT=(20 32 36 39 45 55 65 78 100)
declare -a CORE_CLOCKS=()
declare -a MEM_CLOCKS=()
declare -A SUPPORTED_PAIR=()

usage() {
    cat <<'EOF'
Usage: vrchat-gpu-monitor.sh [--gpu INDEX] [--poll SECONDS] [--force]

Monitors for VRChat.exe and applies an NVIDIA clock preset while it runs.
Use --force to skip VRChat detection and downclock immediately.

Interactive controls:
  1-9       Preset level, very low through maximum
  -/+       Lower or raise the preset
  c         Set only the GPU core clock (nearest supported value)
  m         Set only the memory clock (nearest supported value)
  p         Return to combined preset mode
  a / Tab   Toggle manual mode: 1-9 set core level, q-o set memory level
            (in manual mode use z to reset and x to quit)
  f         Toggle forced downclocking without VRChat
  r         Reset clocks until VRChat is restarted
  q         Reset clocks and quit

Environment variables GPU, POLL_SECONDS, and FORCE_DOWNCLOCK provide the same settings.
EOF
}

while (($#)); do
    case "$1" in
        --gpu)
            GPU="${2:?--gpu requires an index}"
            shift 2
            ;;
        --poll)
            POLL_SECONDS="${2:?--poll requires seconds}"
            shift 2
            ;;
        --force)
            FORCE_DOWNCLOCK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for command in nvidia-smi; do
    if ! command -v "$command" >/dev/null; then
        printf 'Required command not found: %s\n' "$command" >&2
        exit 1
    fi
done

if ((!FORCE_DOWNCLOCK)) && ! command -v pgrep >/dev/null; then
    printf 'Required command not found: pgrep\n' >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null; then
        printf 'sudo is required to change NVIDIA clocks.\n' >&2
        exit 1
    fi
    printf 'NVIDIA clock changes require sudo authentication.\n'
    sudo -v || exit 1
    (
        while kill -0 "$MAIN_PID" 2>/dev/null; do
            sudo -n -v >/dev/null 2>&1 || exit
            sleep 50
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
fi

gpu_admin() {
    if [[ $EUID -eq 0 ]]; then
        nvidia-smi -i "$GPU" "$@"
    else
        sudo -n nvidia-smi -i "$GPU" "$@"
    fi
}

load_supported_clocks() {
    local memory graphics
    declare -A seen_core=() seen_mem=()

    while IFS=, read -r memory graphics; do
        memory=${memory//[^0-9]/}
        graphics=${graphics//[^0-9]/}
        [[ -n $memory && -n $graphics ]] || continue
        SUPPORTED_PAIR["$graphics,$memory"]=1
        if [[ -z ${seen_mem[$memory]+x} ]]; then
            MEM_CLOCKS+=("$memory")
            seen_mem[$memory]=1
        fi
        if [[ -z ${seen_core[$graphics]+x} ]]; then
            CORE_CLOCKS+=("$graphics")
            seen_core[$graphics]=1
        fi
    done < <(nvidia-smi -i "$GPU" --query-supported-clocks=memory,graphics --format=csv,noheader,nounits 2>/dev/null)

    if ((${#CORE_CLOCKS[@]} == 0 || ${#MEM_CLOCKS[@]} == 0)); then
        printf 'Could not read supported clocks for GPU %s.\n' "$GPU" >&2
        exit 1
    fi
}

nearest_clock() {
    local wanted=$1
    shift
    local value distance best="" best_distance=2147483647

    for value in "$@"; do
        distance=$((value - wanted))
        ((distance < 0)) && distance=$((-distance))
        if ((distance < best_distance)); then
            best=$value
            best_distance=$distance
        fi
    done
    printf '%s' "$best"
}

nearest_compatible_memory() {
    local wanted=$1 core=$2
    local memory distance best="" best_distance=2147483647

    for memory in "${MEM_CLOCKS[@]}"; do
        [[ -n ${SUPPORTED_PAIR["$core,$memory"]+x} ]] || continue
        distance=$((memory - wanted))
        ((distance < 0)) && distance=$((-distance))
        if ((distance < best_distance)); then
            best=$memory
            best_distance=$distance
        fi
    done
    printf '%s' "$best"
}

game_running() {
    ((FORCE_DOWNCLOCK)) && return 0
    pgrep -fi '(^|[/\\])VRChat\.exe([[:space:]]|$)' >/dev/null
}

reset_clocks() {
    local output rc=0
    if ! output=$(gpu_admin -rgc 2>&1); then
        MESSAGE="Core reset failed: $output"
        rc=1
    fi
    if ! output=$(gpu_admin -rmc 2>&1); then
        MESSAGE="Memory reset failed: $output"
        rc=1
    fi
    LIMITED=0
    ((rc == 0)) && MESSAGE="GPU clocks restored to defaults"
    return "$rc"
}

apply_profile() {
    apply_pair "${PROFILE_CORE[$PROFILE]}" "${PROFILE_MEM[$PROFILE]}" "${PROFILE_NAMES[$PROFILE]} preset"
}

apply_manual() {
    apply_pair "${MANUAL_CORE[$MANUAL_CORE_IDX]}" "${MANUAL_MEM[$MANUAL_MEM_IDX]}" "manual"
}

apply_pair() {
    local core=$1 memory=$2 label=$3
    local output actual_memory display_active

    if ! output=$(gpu_admin -lgc "$core" 2>&1); then
        local error="Core limit failed: $output"
        reset_clocks >/dev/null 2>&1 || true
        MESSAGE=$error
        return 1
    fi
    if ! output=$(gpu_admin -lmc "$memory,$memory" 2>&1); then
        local error="Memory limit failed: $output"
        reset_clocks >/dev/null 2>&1 || true
        MESSAGE=$error
        return 1
    fi
    LIMITED=1
    sleep 0.2
    actual_memory=$(nvidia-smi -i "$GPU" --query-gpu=clocks.mem --format=csv,noheader,nounits 2>/dev/null)
    actual_memory=${actual_memory//[^0-9]/}
    if [[ -n $actual_memory && $actual_memory != "$memory" ]]; then
        display_active=$(nvidia-smi -i "$GPU" --query-gpu=display_active --format=csv,noheader 2>/dev/null)
        MESSAGE="Memory requested ${memory} MHz, but driver kept ${actual_memory} MHz (display: ${display_active:-unknown})"
    else
        MESSAGE="Applied ${label}: ${core}/${memory} MHz"
    fi
}

apply_core_only() {
    local output

    if ! output=$(gpu_admin -rmc 2>&1); then
        MESSAGE="Memory reset failed: $output"
        return 1
    fi
    if ! output=$(gpu_admin -lgc "$CUSTOM_CORE" 2>&1); then
        local error="Core limit failed: $output"
        reset_clocks >/dev/null 2>&1 || true
        MESSAGE=$error
        return 1
    fi
    LIMITED=1
    MESSAGE="Applied core-only limit: ${CUSTOM_CORE} MHz; memory is default"
}

apply_memory_only() {
    local output actual_memory display_active

    if ! output=$(gpu_admin -rgc 2>&1); then
        MESSAGE="Core reset failed: $output"
        return 1
    fi
    if ! output=$(gpu_admin -lmc "$CUSTOM_MEM,$CUSTOM_MEM" 2>&1); then
        local error="Memory limit failed: $output"
        reset_clocks >/dev/null 2>&1 || true
        MESSAGE=$error
        return 1
    fi
    LIMITED=1
    sleep 0.2
    actual_memory=$(nvidia-smi -i "$GPU" --query-gpu=clocks.mem --format=csv,noheader,nounits 2>/dev/null)
    actual_memory=${actual_memory//[^0-9]/}
    if [[ -n $actual_memory && $actual_memory != "$CUSTOM_MEM" ]]; then
        display_active=$(nvidia-smi -i "$GPU" --query-gpu=display_active --format=csv,noheader 2>/dev/null)
        MESSAGE="Memory requested ${CUSTOM_MEM} MHz, but driver kept ${actual_memory} MHz (display: ${display_active:-unknown})"
    else
        MESSAGE="Applied memory-only limit: ${CUSTOM_MEM} MHz; core is default"
    fi
}

apply_selection() {
    case "$MODE" in
        preset) apply_profile ;;
        core) apply_core_only ;;
        memory) apply_memory_only ;;
        manual) apply_manual ;;
    esac
}

cleanup() {
    trap - EXIT INT TERM HUP
    if ((LIMITED)); then
        reset_clocks >/dev/null 2>&1 || true
    fi
    if [[ -n $SUDO_KEEPALIVE_PID ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM HUP

load_supported_clocks
MAX_CORE=0
MAX_MEM=0
for value in "${CORE_CLOCKS[@]}"; do ((value > MAX_CORE)) && MAX_CORE=$value; done
for value in "${MEM_CLOCKS[@]}"; do ((value > MAX_MEM)) && MAX_MEM=$value; done

# Memory is prioritized: always use the highest memory clock, and pick cores
# only from those the driver supports together with it.
declare -a MAX_MEM_CORES=()
for value in "${CORE_CLOCKS[@]}"; do
    [[ -n ${SUPPORTED_PAIR["$value,$MAX_MEM"]+x} ]] && MAX_MEM_CORES+=("$value")
done
((${#MAX_MEM_CORES[@]})) || MAX_MEM_CORES=("${CORE_CLOCKS[@]}")

declare -a PROFILE_CORE=() PROFILE_MEM=()
for i in "${!PROFILE_NAMES[@]}"; do
    PROFILE_CORE+=("$(nearest_clock "$((MAX_CORE * CORE_PERCENT[i] / 100))" "${MAX_MEM_CORES[@]}")")
    PROFILE_MEM+=("$(nearest_compatible_memory "$MAX_MEM" "${PROFILE_CORE[$i]}")")
done
CUSTOM_CORE=${PROFILE_CORE[$PROFILE]}
CUSTOM_MEM=$MAX_MEM

# Manual mode: 9 core levels (keys 1-9) and 9 memory levels (keys q-o),
# each from lowest to highest, spread across the supported clocks.
MANUAL_KEYS="qwertyuio"
declare -a MANUAL_CORE=() MANUAL_MEM=()
mapfile -t SORTED_MEM < <(printf '%s\n' "${MEM_CLOCKS[@]}" | sort -n)
for i in "${!CORE_PERCENT[@]}"; do
    MANUAL_CORE+=("$(nearest_clock "$((MAX_CORE * CORE_PERCENT[i] / 100))" "${CORE_CLOCKS[@]}")")
    MANUAL_MEM+=("${SORTED_MEM[$(( (i * (${#SORTED_MEM[@]} - 1) + 4) / 8 ))]}")
done
MANUAL_CORE_IDX=$PROFILE
MANUAL_MEM_IDX=8

render() {
    local game_status="stopped" limit_status="defaults"
    local stats
    if ((FORCE_DOWNCLOCK)); then
        game_status="FORCED"
    elif ((GAME_STATE)); then
        game_status="RUNNING"
    fi
    ((LIMITED)) && limit_status="limited"
    stats=$(nvidia-smi -i "$GPU" --query-gpu=name,pstate,utilization.gpu,power.draw,clocks.gr,clocks.mem,temperature.gpu --format=csv,noheader 2>/dev/null || printf 'unavailable')

    printf '\033[H\033[2J'
    printf 'VRChat GPU Monitor  |  GPU %s  |  VRChat: %s  |  %s\n' "$GPU" "$game_status" "$limit_status"
    printf '%s\n\n' "$stats"
    if [[ $CONTROL_MODE == manual ]]; then
        printf '  Core:   '
        for i in "${!MANUAL_CORE[@]}"; do
            ((i)) && printf ' | '
            mark=' '; ((i == MANUAL_CORE_IDX)) && mark='*'
            printf '[%d]%s%-5s' "$((i + 1))" "$mark" "${MANUAL_CORE[$i]}"
        done
        printf '\n  Memory: '
        for i in "${!MANUAL_MEM[@]}"; do
            ((i)) && printf ' | '
            mark=' '; ((i == MANUAL_MEM_IDX)) && mark='*'
            printf '[%s]%s%-5s' "${MANUAL_KEYS:i:1}" "$mark" "${MANUAL_MEM[$i]}"
        done
        printf '\n\nSelected: Manual %s core / %s memory MHz\n' "${MANUAL_CORE[$MANUAL_CORE_IDX]}" "${MANUAL_MEM[$MANUAL_MEM_IDX]}"
        printf 'Controls: 1-9 core, q-o memory, a/Tab preset mode, f force, z reset, x quit\n'
        printf '%s\n' "$MESSAGE"
        return
    fi
    for i in "${!PROFILE_NAMES[@]}"; do
        printf '  [%d] %-10s %4s core / %5s memory MHz\n' "$((i + 1))" "${PROFILE_NAMES[$i]}" "${PROFILE_CORE[$i]}" "${PROFILE_MEM[$i]}"
    done
    printf '\n'
    case "$MODE" in
        preset) selection="Preset ${PROFILE_NAMES[$PROFILE]}" ;;
        core) selection="Core only: ${CUSTOM_CORE} MHz" ;;
        memory) selection="Memory only: ${CUSTOM_MEM} MHz" ;;
        *) selection="Manual" ;;
    esac
    printf 'Selected: %s\n' "$selection"
    printf 'Controls: 1-9/-/+ preset, c core-only, m memory-only, p preset, a/Tab manual mode, f force, r/z reset, q/x quit\n'
    printf '%s\n' "$MESSAGE"
}

prompt_clock() {
    local domain=$1 value supported

    printf '\033[?25h'
    if [[ $domain == core ]]; then
        printf '\nEnter desired core MHz (it will snap to the nearest supported clock): '
    else
        printf '\nSupported memory MHz: %s\n' "${MEM_CLOCKS[*]}"
        printf 'Enter desired memory MHz (it will snap to the nearest supported clock): '
    fi

    if ! IFS= read -r value || [[ ! $value =~ ^[0-9]+$ ]]; then
        MESSAGE="Invalid clock; enter a positive whole number"
        printf '\033[?25l'
        return
    fi

    if [[ $domain == core ]]; then
        CUSTOM_CORE=$(nearest_clock "$value" "${CORE_CLOCKS[@]}")
        MODE="core"
        supported=$CUSTOM_CORE
    else
        CUSTOM_MEM=$(nearest_clock "$value" "${MEM_CLOCKS[@]}")
        MODE="memory"
        supported=$CUSTOM_MEM
    fi
    printf '\033[?25l'

    if ((GAME_STATE)); then
        apply_selection || true
    else
        MESSAGE="Selected ${domain}-only ${supported} MHz for next VRChat launch"
    fi
}

INTERACTIVE=0
[[ -t 0 && -t 1 ]] && INTERACTIVE=1
((INTERACTIVE)) && printf '\033[?25l'
trap 'printf "\033[?25h"; cleanup; exit 0' EXIT INT TERM HUP

while true; do
    if game_running; then GAME_STATE=1; else GAME_STATE=0; fi

    if ((GAME_STATE != LAST_GAME_STATE)); then
        if ((GAME_STATE)); then
            apply_selection || true
        elif ((LIMITED)); then
            reset_clocks || true
        else
            MESSAGE="Waiting for VRChat.exe"
        fi
        LAST_GAME_STATE=$GAME_STATE
    fi

    if ((INTERACTIVE)); then
        render
        key=""
        if IFS= read -rsn1 -t "$POLL_SECONDS" key; then
            if [[ $key == $'\t' || $key == a || $key == A ]]; then
                if [[ $CONTROL_MODE == manual ]]; then
                    CONTROL_MODE=preset
                    MODE=preset
                else
                    CONTROL_MODE=manual
                    MODE=manual
                fi
                if ((GAME_STATE)); then
                    apply_selection || true
                else
                    MESSAGE="Switched to ${CONTROL_MODE} mode"
                fi
                continue
            fi
            if [[ $CONTROL_MODE == manual ]]; then
                case "$key" in
                    [1-9])
                        MANUAL_CORE_IDX=$((key - 1))
                        ;;
                    [qwertyuioQWERTYUIO])
                        lower=${key,,}
                        prefix=${MANUAL_KEYS%%"$lower"*}
                        MANUAL_MEM_IDX=${#prefix}
                        ;;
                    f|F|z|Z|x|X)
                        ;;
                    *)
                        continue
                        ;;
                esac
                case "$key" in
                    [1-9]|[qwertyuioQWERTYUIO])
                        MODE=manual
                        if ((GAME_STATE)); then
                            apply_selection || true
                        else
                            MESSAGE="Selected manual ${MANUAL_CORE[$MANUAL_CORE_IDX]}/${MANUAL_MEM[$MANUAL_MEM_IDX]} MHz for next launch"
                        fi
                        continue
                        ;;
                    z|Z) key=r ;;
                    x|X) key=q ;;
                esac
            fi
            case "$key" in
                [1-9])
                    PROFILE=$((key - 1))
                    MODE="preset"
                    if ((GAME_STATE)); then
                        apply_selection || true
                    else
                        MESSAGE="Selected ${PROFILE_NAMES[$PROFILE]} for next launch"
                    fi
                    ;;
                -)
                    ((PROFILE > 0)) && PROFILE=$((PROFILE - 1))
                    MODE="preset"
                    if ((GAME_STATE)); then
                        apply_selection || true
                    else
                        MESSAGE="Selected ${PROFILE_NAMES[$PROFILE]} for next launch"
                    fi
                    ;;
                +|=)
                    ((PROFILE < ${#PROFILE_NAMES[@]} - 1)) && PROFILE=$((PROFILE + 1))
                    MODE="preset"
                    if ((GAME_STATE)); then
                        apply_selection || true
                    else
                        MESSAGE="Selected ${PROFILE_NAMES[$PROFILE]} for next launch"
                    fi
                    ;;
                c|C)
                    prompt_clock core
                    ;;
                m|M)
                    prompt_clock memory
                    ;;
                p|P)
                    MODE="preset"
                    if ((GAME_STATE)); then
                        apply_selection || true
                    else
                        MESSAGE="Selected ${PROFILE_NAMES[$PROFILE]} preset for next launch"
                    fi
                    ;;
                f|F)
                    if ((FORCE_DOWNCLOCK)); then
                        FORCE_DOWNCLOCK=0
                        if pgrep -fi '(^|[/\\])VRChat\.exe([[:space:]]|$)' >/dev/null; then
                            GAME_STATE=1
                            MESSAGE="Forced downclock disabled; VRChat is running"
                        else
                            GAME_STATE=0
                            reset_clocks || true
                        fi
                    else
                        FORCE_DOWNCLOCK=1
                        GAME_STATE=1
                        apply_selection || true
                    fi
                    LAST_GAME_STATE=$GAME_STATE
                    ;;
                r|R|z|Z)
                    reset_clocks || true
                    ;;
                q|Q|x|X)
                    exit 0
                    ;;
            esac
        fi
    else
        if ((GAME_STATE != LAST_LOGGED_STATE)); then
            printf '%(%F %T)T %s\n' -1 "$MESSAGE"
            LAST_LOGGED_STATE=$GAME_STATE
        fi
        sleep "$POLL_SECONDS"
    fi
done
