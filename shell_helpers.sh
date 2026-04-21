#!/usr/bin/env bash

MIHOMO_HOME="/data01/home/xuzk/mihomo"

mihomostart() {
  "$MIHOMO_HOME/start.sh"
}

mihomostop() {
  "$MIHOMO_HOME/stop.sh"
}

mihomorestart() {
  "$MIHOMO_HOME/restart.sh"
}

mihomostatus() {
  "$MIHOMO_HOME/status.sh"
}

mihomoui() {
  "$MIHOMO_HOME/status.sh" | rg 'LAN UI:|Local UI:|LAN Sub:|Sub UI:' || "$MIHOMO_HOME/status.sh"
}

mihomoon() {
  export http_proxy="http://127.0.0.1:30419"
  export https_proxy="$http_proxy"
  export HTTP_PROXY="$http_proxy"
  export HTTPS_PROXY="$http_proxy"
  export all_proxy="socks5h://127.0.0.1:30420"
  export ALL_PROXY="$all_proxy"
  export no_proxy="localhost,127.0.0.1,::1"
  export NO_PROXY="$no_proxy"
  echo "Proxy env enabled via 127.0.0.1:30419 / 127.0.0.1:30420"
}

mihomooff() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  unset all_proxy ALL_PROXY no_proxy NO_PROXY
  echo "Proxy env disabled"
}

# Compatibility wrappers for the old clashctl shell habits.
clashon() {
  mihomoon
}

clashoff() {
  mihomooff
}

clashrestart() {
  mihomorestart
}

clashstatus() {
  mihomostatus
}

clashui() {
  mihomoui
}

clashupdate() {
  "$MIHOMO_HOME/update-subscription.sh" "$@"
}
