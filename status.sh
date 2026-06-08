#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

clear_stale_pid
clear_stale_admin_pid

echo "Base dir:  $BASE_DIR"
echo "Config:    $CONFIG_FILE"
echo "Raw conf:  $RAW_CONFIG"
echo "Log:       $LOG_FILE"
echo "Local UI:  $(ui_url_local)"
echo "Sub UI:    $(subscription_ui_url_local)"
echo "Admin API: $(admin_api_url_local)"
lan_url="$(ui_url_lan || true)"
if [[ -n "${lan_url:-}" ]]; then
  echo "LAN UI:    $lan_url"
fi
sub_lan_url="$(subscription_ui_url_lan || true)"
if [[ -n "${sub_lan_url:-}" ]]; then
  echo "LAN Sub:   $sub_lan_url"
fi
admin_lan_url="$(admin_api_url_lan || true)"
if [[ -n "${admin_lan_url:-}" ]]; then
  echo "LAN API:   $admin_lan_url"
fi

secret="$(get_secret)"
if [[ -n "$secret" ]]; then
  echo "Secret:    $secret"
else
  echo "Secret:    <empty>"
fi

if [[ -f "$SUBSCRIPTION_FILE" ]]; then
  echo "Sub URL:   $(<"$SUBSCRIPTION_FILE")"
fi

if has_user_service; then
  current_status="$(service_status)"
  [[ -z "$current_status" ]] && current_status="unknown"
  echo "Status:    $current_status (systemd)"
  main_pid="$(service_main_pid)"
  if [[ -n "${main_pid:-}" && "$main_pid" != "0" ]]; then
    echo "PID:       $main_pid"
  fi
  if has_admin_user_service; then
    admin_status="$(systemctl --user is-active "$ADMIN_SERVICE" 2>/dev/null || true)"
    [[ -z "$admin_status" ]] && admin_status="unknown"
    echo "Admin:     $admin_status (systemd)"
  fi
elif is_running; then
  if ui_is_available; then
    echo "Status:    running"
  else
    echo "Status:    unhealthy"
  fi
  echo "PID:       $(running_pid)"
  if is_admin_running; then
    if admin_is_available; then
      echo "Admin:     running"
    else
      echo "Admin:     unhealthy"
    fi
    echo "Admin PID: $(running_admin_pid)"
  else
    echo "Admin:     stopped"
  fi
else
  echo "Status:    stopped"
  if is_admin_running; then
    if admin_is_available; then
      echo "Admin:     running"
    else
      echo "Admin:     unhealthy"
    fi
    echo "Admin PID: $(running_admin_pid)"
  else
    echo "Admin:     stopped"
  fi
fi
