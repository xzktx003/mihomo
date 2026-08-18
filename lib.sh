#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIHOMO_BIN="$BASE_DIR/mihomo"
YQ_BIN="$BASE_DIR/bin/yq"
RAW_CONFIG="$BASE_DIR/config.raw.yaml"
MIXIN_CONFIG="$BASE_DIR/mixin.yaml"
LOCAL_MIXIN_CONFIG="$BASE_DIR/mixin.local.yaml"
CONFIG_FILE="$BASE_DIR/config.yaml"
SUBSCRIPTION_FILE="$BASE_DIR/.subscription_url"
PID_FILE="$BASE_DIR/mihomo.pid"
ADMIN_PID_FILE="$BASE_DIR/mihomo-admin.pid"
LOG_FILE="$BASE_DIR/mi.log"
ADMIN_LOG_FILE="$BASE_DIR/subscription-admin.log"
BACKUP_DIR="$BASE_DIR/backups"
TMP_DIR="$BASE_DIR/tmp"
SYSTEMD_SERVICE="mihomo.service"
SYSTEMD_SERVICE_FILE="$HOME/.config/systemd/user/$SYSTEMD_SERVICE"
ADMIN_SERVICE="mihomo-admin.service"
ADMIN_SERVICE_FILE="$HOME/.config/systemd/user/$ADMIN_SERVICE"
SUBSCRIPTION_USER_AGENT="${MIHOMO_SUBSCRIPTION_USER_AGENT:-mihomo/1.19.2}"

ensure_layout() {
  mkdir -p "$BACKUP_DIR" "$TMP_DIR"
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing required file: $path" >&2
    exit 1
  fi
}

clear_stale_pid() {
  if [[ -f "$PID_FILE" ]] && ! is_running; then
    rm -f "$PID_FILE"
  fi
}

find_mihomo_pid() {
  local proc cmdline
  for proc in /proc/[0-9]*; do
    [[ -r "$proc/cmdline" ]] || continue
    cmdline="$(tr '\0' ' ' 2>/dev/null <"$proc/cmdline" || true)"
    cmdline="${cmdline% }"
    if [[ "$cmdline" == "$MIHOMO_BIN -d $BASE_DIR -f $CONFIG_FILE" ]]; then
      echo "${proc##*/}"
      return 0
    fi
  done
  return 1
}

is_running() {
  if [[ ! -f "$PID_FILE" ]]; then
    local discovered_pid
    discovered_pid="$(find_mihomo_pid || true)"
    if [[ -n "$discovered_pid" ]]; then
      echo "$discovered_pid" >"$PID_FILE"
    else
      return 1
    fi
  fi
  local pid
  pid="$(<"$PID_FILE")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

running_pid() {
  if is_running; then
    <"$PID_FILE" cat
  fi
}

has_user_service() {
  command -v systemctl >/dev/null 2>&1 && \
    systemctl --user show-environment >/dev/null 2>&1 && \
    [[ -f "$SYSTEMD_SERVICE_FILE" ]]
}

has_admin_user_service() {
  command -v systemctl >/dev/null 2>&1 && \
    systemctl --user show-environment >/dev/null 2>&1 && \
    [[ -f "$ADMIN_SERVICE_FILE" ]]
}

clear_stale_admin_pid() {
  if [[ -f "$ADMIN_PID_FILE" ]] && ! is_admin_running; then
    rm -f "$ADMIN_PID_FILE"
  fi
}

find_admin_pid() {
  local proc cmdline
  for proc in /proc/[0-9]*; do
    [[ -r "$proc/cmdline" ]] || continue
    cmdline="$(tr '\0' ' ' 2>/dev/null <"$proc/cmdline" || true)"
    cmdline="${cmdline% }"
    if [[ "$cmdline" == *" $BASE_DIR/subscription_admin.py --host 0.0.0.0 --port 9091" ]]; then
      echo "${proc##*/}"
      return 0
    fi
  done
  return 1
}

is_admin_running() {
  if [[ ! -f "$ADMIN_PID_FILE" ]]; then
    local discovered_pid
    discovered_pid="$(find_admin_pid || true)"
    if [[ -n "$discovered_pid" ]]; then
      echo "$discovered_pid" >"$ADMIN_PID_FILE"
    else
      return 1
    fi
  fi
  local pid
  pid="$(<"$ADMIN_PID_FILE")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

running_admin_pid() {
  if is_admin_running; then
    <"$ADMIN_PID_FILE" cat
  fi
}

service_is_active() {
  has_user_service || return 1
  systemctl --user is-active --quiet "$SYSTEMD_SERVICE"
}

service_status() {
  if has_user_service; then
    systemctl --user is-active "$SYSTEMD_SERVICE" 2>/dev/null || true
  fi
}

service_main_pid() {
  if has_user_service; then
    systemctl --user show -p MainPID --value "$SYSTEMD_SERVICE" 2>/dev/null || true
  fi
}

get_controller_addr() {
  require_file "$CONFIG_FILE"
  "$YQ_BIN" -r '.["external-controller"] // "127.0.0.1:9090"' "$CONFIG_FILE"
}

get_controller_port() {
  local addr
  addr="$(get_controller_addr)"
  echo "${addr##*:}"
}

get_secret() {
  require_file "$CONFIG_FILE"
  "$YQ_BIN" -r '.secret // ""' "$CONFIG_FILE"
}

get_local_ip() {
  local ip_addr
  ip_addr="$(ip route get 1.1.1.1 2>/dev/null | awk 'NR == 1 { print $7 }')"
  if [[ -z "$ip_addr" ]]; then
    ip_addr="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
  fi
  echo "$ip_addr"
}

ui_url_local() {
  echo "http://127.0.0.1:$(get_controller_port)/ui"
}

ui_url_lan() {
  local ip_addr
  ip_addr="$(get_local_ip)"
  if [[ -n "$ip_addr" ]]; then
    echo "http://$ip_addr:$(get_controller_port)/ui"
  fi
}

subscription_ui_url_local() {
  echo "$(ui_url_local)/subscription.html"
}

subscription_ui_url_lan() {
  local ip_addr
  ip_addr="$(get_local_ip)"
  if [[ -n "$ip_addr" ]]; then
    echo "http://$ip_addr:$(get_controller_port)/ui/subscription.html"
  fi
}

admin_api_url_local() {
  echo "http://127.0.0.1:9091"
}

admin_api_url_lan() {
  local ip_addr
  ip_addr="$(get_local_ip)"
  if [[ -n "$ip_addr" ]]; then
    echo "http://$ip_addr:9091"
  fi
}

backup_configs() {
  ensure_layout
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local dir="$BACKUP_DIR/$stamp"
  mkdir -p "$dir"
  [[ -f "$RAW_CONFIG" ]] && cp -f "$RAW_CONFIG" "$dir/config.raw.yaml"
  [[ -f "$CONFIG_FILE" ]] && cp -f "$CONFIG_FILE" "$dir/config.yaml"
  echo "$dir"
}

merge_config() {
  ensure_layout
  require_file "$MIHOMO_BIN"
  require_file "$YQ_BIN"
  require_file "$RAW_CONFIG"
  require_file "$MIXIN_CONFIG"

  local tmp_config
  tmp_config="$TMP_DIR/config.yaml.$$"
  local merge_output
  local test_output
  local -a merge_sources=("$MIXIN_CONFIG" "$RAW_CONFIG" "$MIXIN_CONFIG")

  if [[ -f "$LOCAL_MIXIN_CONFIG" ]]; then
    merge_sources+=("$LOCAL_MIXIN_CONFIG")
  fi

  if ! merge_output="$("$YQ_BIN" eval-all \
    '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
    "${merge_sources[@]}" 2>&1 >"$tmp_config")"; then
    rm -f "$tmp_config"
    [[ -n "$merge_output" ]] && printf '%s\n' "$merge_output" >&2
    return 1
  fi

  if ! test_output="$("$MIHOMO_BIN" -t -d "$BASE_DIR" -f "$tmp_config" 2>&1)"; then
    rm -f "$tmp_config"
    [[ -n "$test_output" ]] && printf '%s\n' "$test_output" >&2
    return 1
  fi

  mv "$tmp_config" "$CONFIG_FILE"
}

download_subscription() {
  local source_path="$1"
  local target_path="$2"
  local curl_status=0
  local ua
  local -a user_agents=("$SUBSCRIPTION_USER_AGENT" "clash.meta")

  case "$source_path" in
    http://*|https://*)
      if command -v curl >/dev/null 2>&1; then
        for ua in "${user_agents[@]}"; do
          if curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 \
            -A "$ua" \
            -H 'Accept: */*' \
            "$source_path" -o "$target_path"; then
            return 0
          else
            curl_status=$?
          fi
        done
        for ua in "${user_agents[@]}"; do
          if env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
            curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 \
            -A "$ua" \
            -H 'Accept: */*' \
            "$source_path" -o "$target_path"; then
            return 0
          else
            curl_status=$?
          fi
        done
        return "$curl_status"
      elif command -v wget >/dev/null 2>&1; then
        wget -qO "$target_path" --timeout=10 --tries=2 --user-agent="$SUBSCRIPTION_USER_AGENT" "$source_path"
      else
        echo "Neither curl nor wget is available." >&2
        return 1
      fi
      ;;
    file://*)
      cp -f "${source_path#file://}" "$target_path"
      ;;
    *)
      if [[ -f "$source_path" ]]; then
        cp -f "$source_path" "$target_path"
      else
        echo "Unsupported subscription source: $source_path" >&2
        return 1
      fi
      ;;
  esac
}

wait_for_ui() {
  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi

  local url
  url="$(ui_url_local)"
  local attempt

  for attempt in $(seq 1 15); do
    if curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null || \
       curl -fsS -o /dev/null --max-time 2 "$url/" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  return 1
}

ui_is_available() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS -o /dev/null --max-time 2 "$(ui_url_local)" 2>/dev/null || \
    curl -fsS -o /dev/null --max-time 2 "$(ui_url_local)/" 2>/dev/null
}

admin_is_available() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS -o /dev/null --max-time 2 "$(admin_api_url_local)/api/health" 2>/dev/null
}
