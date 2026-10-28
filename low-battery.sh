#!/usr/bin/env bash

set -euo pipefail

# ==========================================
# User configuration
# ==========================================

readonly BATTERY_THRESHOLD=20
readonly LOW_BATTERY_ACTION="suspend"  # suspend or shutdown
readonly WARNING_SECONDS=90

# ==========================================
# Prevent concurrent instances
# ==========================================

LOCK_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/low-battery.lock"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    echo "Another instance is running; exiting."
    exit 0
fi

# Keep file descriptor 9 open for the entire script.
# The lock is released automatically when the script exits.

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
    echo "Error: BATTERY_THRESHOLD must be 0-100." >&2
    exit 1
fi

if (( WARNING_SECONDS < 1 )); then
    echo "Error: WARNING_SECONDS must be positive." >&2
    exit 1
fi

if [[ "$LOW_BATTERY_ACTION" != "suspend" &&
      "$LOW_BATTERY_ACTION" != "shutdown" ]]; then
    echo "Error: Invalid LOW_BATTERY_ACTION." >&2
    exit 1
fi

if ! currentBatteryPercentage=$(get_battery_percentage); then
    echo "Error: Could not read battery percentage." >&2
    exit 1
fi

echo "Battery: ${currentBatteryPercentage}%"

if (( currentBatteryPercentage >= BATTERY_THRESHOLD )); then
    echo "Battery above threshold; no action."
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

cancelled=false

if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] &&
   command -v zenity >/dev/null 2>&1; then

    # One button only: clicking it cancels the action.
    # Timeout closes the dialog and allows the action to proceed.
    if zenity --info \
        --title="Low battery warning" \
        --text="$warning_message" \
        --ok-label="Cancel action" \
        --timeout="$WARNING_SECONDS"; then
        cancelled=true
    fi
else
    # Terminal fallback. No graphical session is available.
    echo "Press c then Enter within ${WARNING_SECONDS} seconds to cancel."

    if IFS= read -r -t "$WARNING_SECONDS" -p "> " response; then
        if [[ "$response" == "c" || "$response" == "C" ]]; then
            cancelled=true
        fi
    fi
fi

if [[ "$cancelled" == true ]]; then
    echo "Action cancelled by user."
    exit 0
fi

# ==========================================
# Recheck battery after warning
# ==========================================

if ! currentBatteryPercentage=$(get_battery_percentage); then
    echo "Error: Could not re-read battery; taking no action." >&2
    exit 1
fi

echo "Battery after warning: ${currentBatteryPercentage}%"

if (( currentBatteryPercentage >= BATTERY_THRESHOLD )); then
    echo "Battery recovered; no action."
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
