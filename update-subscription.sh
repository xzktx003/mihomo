#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

ensure_layout

subscription_url="${1:-}"
if [[ -z "$subscription_url" && -f "$SUBSCRIPTION_FILE" ]]; then
  subscription_url="$(<"$SUBSCRIPTION_FILE")"
fi

if [[ -z "$subscription_url" ]]; then
  echo "Usage: $0 <clash-or-mihomo-subscription-url>" >&2
  exit 1
fi

backup_dir="$(backup_configs)"
tmp_raw="$TMP_DIR/subscription.yaml.$$"
trap 'rm -f "$tmp_raw"' EXIT

restore_backup() {
  [[ -f "$backup_dir/config.raw.yaml" ]] && cp -f "$backup_dir/config.raw.yaml" "$RAW_CONFIG"
  [[ -f "$backup_dir/config.yaml" ]] && cp -f "$backup_dir/config.yaml" "$CONFIG_FILE"
}

if ! download_subscription "$subscription_url" "$tmp_raw"; then
  restore_backup
  echo "Subscription download failed. Restored backup from $backup_dir" >&2
  exit 1
fi

if [[ ! -s "$tmp_raw" ]]; then
  restore_backup
  echo "Subscription download produced an empty file. Restored backup from $backup_dir" >&2
  exit 1
fi

cp -f "$tmp_raw" "$RAW_CONFIG"

if ! merge_config; then
  restore_backup
  echo "Subscription update failed. Restored backup from $backup_dir" >&2
  exit 1
fi

printf '%s\n' "$subscription_url" >"$SUBSCRIPTION_FILE"
echo "Subscription saved to $SUBSCRIPTION_FILE"

if has_user_service; then
  if service_is_active; then
    "$SCRIPT_DIR/restart.sh" >/dev/null
    echo "mihomo restarted with the new subscription"
  else
    "$SCRIPT_DIR/start.sh" >/dev/null
    echo "mihomo started with the new subscription"
  fi
elif is_running; then
  "$SCRIPT_DIR/restart.sh" >/dev/null
  echo "mihomo restarted with the new subscription"
elif [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
  "$SCRIPT_DIR/start.sh" >/dev/null
  echo "mihomo started with the new subscription"
else
  echo "Subscription updated. Run $SCRIPT_DIR/start.sh to launch mihomo."
fi
