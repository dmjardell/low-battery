#!/usr/bin/env bash

set -euo pipefail

# ==========================================
# User configuration
# ==========================================

readonly BATTERY_THRESHOLD=15
readonly LOW_BATTERY_ACTION="suspend"  # suspend or shutdown
readonly WARNING_SECONDS=60
readonly COOLDOWN_SECONDS=5400        # 90 minutes

# ==========================================
# Directories and locking
# ==========================================

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/low-battery"
mkdir -p "$STATE_DIR"

LOCK_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/low-battery.lock"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    echo "Another instance is running; exiting."
    exit 0
fi

# ==========================================
# Check external power source
# ==========================================

is_plugged_in() {
    local supply type online

    for supply in /sys/class/power_supply/*; do
        [[ -f "$supply/type" ]] || continue
        [[ -r "$supply/online" ]] || continue

        type=$(<"$supply/type")

        case "$type" in
            Mains|USB|USB_C|USB_PD|USB_PD_DRP|Wireless)
                online=$(<"$supply/online")

                if [[ "$online" == "1" ]]; then
                    return 0
                fi
                ;;
        esac
    done

    return 1
}

if is_plugged_in; then
    echo "External power detected. No action required."
    exit 0
fi

echo "Laptop running on battery."

# ==========================================
# Check cancellation cooldown
# ==========================================

COOLDOWN_FILE="$STATE_DIR/cooldown"

if [[ -f "$COOLDOWN_FILE" ]]; then
    last_abort=$(<"$COOLDOWN_FILE")
    now=$(date +%s)

    if [[ "$last_abort" =~ ^[0-9]+$ ]] &&
       (( now < last_abort )); then
        echo "Cancellation cooldown active. Exiting."
        exit 0
    fi

    if [[ "$last_abort" =~ ^[0-9]+$ ]] &&
       (( now - last_abort < COOLDOWN_SECONDS )); then
        remaining=$((COOLDOWN_SECONDS - (now - last_abort)))
        echo "Cancellation cooldown active. ${remaining}s remaining."
        exit 0
    fi
fi

# ==========================================
# Read battery percentage
# ==========================================

get_battery_percentage() {
    local battery percentage

    for battery in /sys/class/power_supply/*; do
        [[ -f "$battery/type" ]] || continue
        [[ "$(<"$battery/type")" == "Battery" ]] || continue
        [[ -r "$battery/capacity" ]] || continue

        percentage=$(<"$battery/capacity")

        if [[ "$percentage" =~ ^[0-9]+$ ]] &&
           (( percentage >= 0 && percentage <= 100 )); then
            printf '%s\n' "$percentage"
            return 0
        fi
    done

    return 1
}

# ==========================================
# Validate configuration
# ==========================================

if (( BATTERY_THRESHOLD < 0 || BATTERY_THRESHOLD > 100 )); then
    echo "Invalid battery threshold." >&2
    exit 1
fi

if [[ "$LOW_BATTERY_ACTION" != "suspend" &&
      "$LOW_BATTERY_ACTION" != "shutdown" ]]; then
    echo "Invalid action." >&2
    exit 1
fi

if ! currentBatteryPercentage=$(get_battery_percentage); then
    echo "Could not read battery percentage." >&2
    exit 1
fi

echo "Battery: ${currentBatteryPercentage}%"

if (( currentBatteryPercentage >= BATTERY_THRESHOLD )); then
    echo "Battery above threshold. No action."
    exit 0
fi

# ==========================================
# Warn the user
# ==========================================

case "$LOW_BATTERY_ACTION" in
    suspend)  action_description="suspend to RAM" ;;
    shutdown) action_description="shut down" ;;
esac

warning_message="Battery is at ${currentBatteryPercentage}%.

The computer will ${action_description} in ${WARNING_SECONDS} seconds.

Click 'Cancel action' to abort."

echo "$warning_message"

# Require a graphical prompt in the scheduled session.
if ! command -v zenity >/dev/null 2>&1 ||
   [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    echo "Cannot display warning dialog. Taking no action." >&2
    exit 1
fi

# ==========================================
# Cancellation window
# ==========================================

if zenity --info \
    --title="Low battery warning" \
    --text="$warning_message" \
    --ok-label="Cancel action" \
    --timeout="$WARNING_SECONDS"; then

    echo "Action cancelled by user."

    # Store cooldown expiration timestamp.
    now=$(date +%s)
    expiry=$((now + COOLDOWN_SECONDS))

    temp_file=$(mktemp "$STATE_DIR/cooldown.XXXXXX")
    printf '%s\n' "$expiry" > "$temp_file"
    mv "$temp_file" "$COOLDOWN_FILE"

    echo "Next warning permitted in 90 minutes."
    exit 0
fi

# ==========================================
# Recheck power and battery
# ==========================================

if is_plugged_in; then
    echo "External power connected. Aborting action."
    exit 0
fi

if ! currentBatteryPercentage=$(get_battery_percentage); then
    echo "Could not re-read battery. Taking no action." >&2
    exit 1
fi

echo "Battery after warning: ${currentBatteryPercentage}%"

if (( currentBatteryPercentage >= BATTERY_THRESHOLD )); then
    echo "Battery recovered. No action."
    exit 0
fi

# ==========================================
# Execute action
# ==========================================

echo "Executing: $LOW_BATTERY_ACTION"

case "$LOW_BATTERY_ACTION" in
    suspend)
        systemctl suspend
        ;;
    shutdown)
        systemctl poweroff
        ;;
esac
