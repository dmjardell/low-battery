# low-battery
A script that checks if laptop battery percentage is below a certain threshold and if so either suspends or shutdowns. With a gui prompt to abort the process.

Low-battery protection — Linux laptop
- Script installed: ~/.local/bin/low-battery.sh
- Reads battery percentage from /sys/class/power_supply/.
- Configurable threshold (BATTERY_THRESHOLD) and action (suspend or shutdown).
- Displays a 60-second graphical warning using zenity, allowing cancellation.
- Rechecks battery level before executing the action.
- Uses flock to prevent concurrent script instances.
- Systemd user service: ~/.config/systemd/user/low-battery.service
- Executes the script as a one-shot service.
- Systemd user timer: ~/.config/systemd/user/low-battery.timer
- Schedules battery checks every minute.
- Enabled and started with systemctl --user enable --now low-battery.timer.
- Dependencies: zenity, flock (usually provided by util-linux).

- Desktop environment: Imported graphical session variables into the systemd user manager to support graphical dialogs.

- Logs: Available through journalctl --user -u low-battery.service.

Note: Runs under the logged-in user's systemd session; it is not a system-wide service.
