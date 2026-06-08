#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

clear_stale_pid
clear_stale_admin_pid

if has_user_service; then
  if has_admin_user_service; then
    systemctl --user stop "$ADMIN_SERVICE"
  fi
  systemctl --user stop "$SYSTEMD_SERVICE"
  echo "mihomo stopped"
  exit 0
fi

if is_admin_running; then
  admin_pid="$(running_admin_pid)"
  kill "$admin_pid" 2>/dev/null || true
  for _ in $(seq 1 10); do
    if ! kill -0 "$admin_pid" 2>/dev/null; then
      rm -f "$ADMIN_PID_FILE"
      break
    fi
    sleep 1
  done
  if kill -0 "$admin_pid" 2>/dev/null; then
    kill -9 "$admin_pid" 2>/dev/null || true
    rm -f "$ADMIN_PID_FILE"
  fi
fi

if ! is_running; then
  echo "mihomo is not running"
  exit 0
fi

pid="$(running_pid)"
kill "$pid"

for _ in $(seq 1 10); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    echo "mihomo stopped"
    exit 0
  fi
  sleep 1
done

kill -9 "$pid" 2>/dev/null || true
rm -f "$PID_FILE"
echo "mihomo stopped"
