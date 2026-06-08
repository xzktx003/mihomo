#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if has_user_service; then
  systemctl --user restart "$SYSTEMD_SERVICE"
  if has_admin_user_service; then
    systemctl --user restart "$ADMIN_SERVICE"
  fi
  echo "mihomo restarted via systemd user service"
  echo "Local UI: $(ui_url_local)"
  echo "Sub UI:   $(subscription_ui_url_local)"
  if has_admin_user_service; then
    echo "Admin API: $(admin_api_url_local)"
  fi
  exit 0
fi

"$SCRIPT_DIR/stop.sh" >/dev/null
"$SCRIPT_DIR/start.sh"
