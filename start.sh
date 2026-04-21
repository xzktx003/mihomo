#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

clear_stale_pid

if has_user_service; then
  merge_config
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user start "$SYSTEMD_SERVICE"
  echo "mihomo started via systemd user service"
  main_pid="$(service_main_pid)"
  if [[ -n "${main_pid:-}" && "$main_pid" != "0" ]]; then
    echo "PID:      $main_pid"
  fi
  echo "Local UI: $(ui_url_local)"
  echo "Sub UI:   $(subscription_ui_url_local)"
  lan_url="$(ui_url_lan || true)"
  if [[ -n "${lan_url:-}" ]]; then
    echo "LAN UI:   $lan_url"
  fi
  sub_lan_url="$(subscription_ui_url_lan || true)"
  if [[ -n "${sub_lan_url:-}" ]]; then
    echo "LAN Sub:  $sub_lan_url"
  fi
  exit 0
fi

if is_running; then
  echo "mihomo is already running (pid $(running_pid))"
  echo "Local UI: $(ui_url_local)"
  echo "Sub UI:   $(subscription_ui_url_local)"
  lan_url="$(ui_url_lan || true)"
  if [[ -n "${lan_url:-}" ]]; then
    echo "LAN UI:   $lan_url"
  fi
  sub_lan_url="$(subscription_ui_url_lan || true)"
  if [[ -n "${sub_lan_url:-}" ]]; then
    echo "LAN Sub:  $sub_lan_url"
  fi
  exit 0
fi

merge_config

nohup "$MIHOMO_BIN" -d "$BASE_DIR" -f "$CONFIG_FILE" >"$LOG_FILE" 2>&1 &
echo "$!" >"$PID_FILE"
sleep 1

if ! is_running; then
  echo "mihomo failed to start. Check $LOG_FILE" >&2
  exit 1
fi

echo "mihomo started (pid $(running_pid))"
echo "Local UI: $(ui_url_local)"
echo "Sub UI:   $(subscription_ui_url_local)"
lan_url="$(ui_url_lan || true)"
if [[ -n "${lan_url:-}" ]]; then
  echo "LAN UI:   $lan_url"
fi
sub_lan_url="$(subscription_ui_url_lan || true)"
if [[ -n "${sub_lan_url:-}" ]]; then
  echo "LAN Sub:  $sub_lan_url"
fi

if ! wait_for_ui; then
  echo "Controller is still warming up. Check $LOG_FILE if the UI does not open immediately."
fi
