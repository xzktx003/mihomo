#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

clear_stale_pid
clear_stale_admin_pid

start_admin_fallback() {
  if is_admin_running; then
    if ! admin_is_available; then
      admin_pid="$(running_admin_pid)"
      kill "$admin_pid" 2>/dev/null || true
      sleep 1
      if kill -0 "$admin_pid" 2>/dev/null; then
        kill -9 "$admin_pid" 2>/dev/null || true
      fi
      rm -f "$ADMIN_PID_FILE"
    else
      echo "Admin API: $(admin_api_url_local) (pid $(running_admin_pid))"
      return 0
    fi
  fi

  if is_admin_running; then
    echo "Admin API: $(admin_api_url_local) (pid $(running_admin_pid))"
    return 0
  fi

  nohup python3 "$BASE_DIR/subscription_admin.py" --host 0.0.0.0 --port 9091 \
    >>"$ADMIN_LOG_FILE" 2>&1 &
  echo "$!" >"$ADMIN_PID_FILE"
  sleep 1

  if ! is_admin_running; then
    echo "subscription admin failed to start. Check $ADMIN_LOG_FILE" >&2
    return 1
  fi

  if command -v curl >/dev/null 2>&1 && \
     ! curl -fsS -o /dev/null --max-time 2 "$(admin_api_url_local)/api/health"; then
    echo "subscription admin is running but not responding yet. Check $ADMIN_LOG_FILE if the subscription pool does not load." >&2
  fi

  echo "Admin API: $(admin_api_url_local) (pid $(running_admin_pid))"
}

if has_user_service; then
  merge_config
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user start "$SYSTEMD_SERVICE"
  if has_admin_user_service; then
    systemctl --user start "$ADMIN_SERVICE"
  fi
  echo "mihomo started via systemd user service"
  main_pid="$(service_main_pid)"
  if [[ -n "${main_pid:-}" && "$main_pid" != "0" ]]; then
    echo "PID:      $main_pid"
  fi
  echo "Local UI: $(ui_url_local)"
  echo "Sub UI:   $(subscription_ui_url_local)"
  if has_admin_user_service; then
    echo "Admin API: $(admin_api_url_local)"
  fi
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
  if ! ui_is_available; then
    pid="$(running_pid)"
    echo "mihomo process $pid is running but the controller is not responding; restarting it"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
      if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$PID_FILE"
        break
      fi
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
      rm -f "$PID_FILE"
    fi
  fi
fi

if is_running; then
  echo "mihomo is already running (pid $(running_pid))"
  echo "Local UI: $(ui_url_local)"
  echo "Sub UI:   $(subscription_ui_url_local)"
  start_admin_fallback || true
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
start_admin_fallback || true
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
