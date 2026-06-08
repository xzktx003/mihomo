#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if has_user_service; then
  systemctl --user restart "$SYSTEMD_SERVICE"
  echo "mihomo restarted via systemd user service"
  echo "Local UI: $(ui_url_local)"
  echo "Sub UI:   $(subscription_ui_url_local)"
  if has_admin_user_service; then
    echo "Admin API: $(admin_api_url_local)"
  fi
  exit 0
fi

clear_stale_pid
if is_running; then
  pid="$(running_pid)"
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

"$SCRIPT_DIR/start.sh"
