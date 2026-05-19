#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "Run as root"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive

# Temporarily stop Ubuntu/Debian auto-updates and wait for apt/dpkg locks.
apt_lock_pids(){
  command -v fuser >/dev/null 2>&1 || return 0
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null | tr ' ' '\n' | awk 'NF' | sort -u
}
stop_apt_auto_updates(){
  command -v systemctl >/dev/null 2>&1 || return 0
  echo "[APT] Temporarily stopping apt-daily/unattended-upgrades during installer..."
  systemctl stop apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
}
restore_apt_auto_updates(){
  [[ "${RESTORE_APT_AUTO_UPDATE:-1}" == "1" ]] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl start unattended-upgrades.service 2>/dev/null || true
}
wait_for_apt_ready(){
  stop_apt_auto_updates
  local waited=0 max="${APT_LOCK_WAIT_SECONDS:-300}" pids pid args
  while true; do
    pids="$(apt_lock_pids || true)"
    [[ -z "$pids" ]] && break
    echo "[APT] apt/dpkg lock busy by PID(s): $(echo "$pids" | tr '\n' ' ')"
    for pid in $pids; do
      args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ "$args" == *unattended-upgr* || "$args" == *apt.systemd.daily* ]]; then
        if (( waited >= 15 )); then echo "[APT] Asking auto-update PID $pid to stop..."; kill -TERM "$pid" 2>/dev/null || true; fi
        if (( waited >= 60 )); then echo "[APT] Force-stopping stuck auto-update PID $pid..."; kill -KILL "$pid" 2>/dev/null || true; fi
      fi
    done
    if (( waited >= max )); then echo "ERROR: apt/dpkg lock did not release after ${max}s. Try again later." >&2; exit 100; fi
    sleep 5; waited=$((waited+5))
  done
  dpkg --configure -a >/dev/null 2>&1 || true
}
apt_update_install(){
  wait_for_apt_ready
  apt-get update >/dev/null
  wait_for_apt_ready
  apt-get install -y "$@" >/dev/null
}
trap restore_apt_auto_updates EXIT

APP_DIR="${PANEL_DIR:-/var/www/html/panel-admin}"
DATA_DIR="$APP_DIR/data"
V2_PORT="${V2_PORT:-4443}"
CONF_FILE="/etc/vpn-protocols.conf"
XRAY_CFG="/usr/local/etc/xray/config.json"
XRAY_API_PORT="${XRAY_API_PORT:-10085}"
V2_SNI="${V2_SNI:-www.microsoft.com}"
V2_DEST="${V2_DEST:-${V2_SNI}:443}"
V2_EMAIL="${V2_EMAIL:-shared@asiafastvpn}"
SERVER_ADDR="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

is_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
set_conf(){ local k="$1" v="$2"; touch "$CONF_FILE"; if grep -qE "^${k}=" "$CONF_FILE"; then sed -i "s|^${k}=.*|${k}=${v}|" "$CONF_FILE"; else echo "${k}=${v}" >> "$CONF_FILE"; fi; chmod 644 "$CONF_FILE"; }
port_used(){ local port="$1"; ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; }
rand_hex(){ local n="${1:-8}"; openssl rand -hex "$n" 2>/dev/null || head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
read_env(){ local k="$1" d="${2:-}" f="$DATA_DIR/v2ray.env"; [[ -f "$f" ]] && grep -E "^${k}=" "$f" | tail -1 | cut -d= -f2- || printf '%s' "$d"; }

find_xray_bin(){
  local b
  for b in "${XRAY_BIN:-}" "$(command -v xray 2>/dev/null || true)" /usr/local/bin/xray /usr/bin/xray; do
    [[ -n "$b" && -x "$b" ]] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

install_or_update_xray(){
  echo "[V2Ray/Xray] Installing/updating Xray core..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" install >/dev/null
  hash -r 2>/dev/null || true
}

generate_reality_keypair(){
  local bin out priv pub
  bin="$(find_xray_bin || true)"
  [[ -n "$bin" ]] || return 1
  # Xray output can vary slightly by version: "Private key:" or "PrivateKey:".
  out="$($bin x25519 2>&1 || true)"
  priv="$(printf '%s\n' "$out" | sed -nE 's/.*[Pp]rivate[[:space:]_-]*[Kk]ey[[:space:]]*:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' | head -1)"
  pub="$(printf '%s\n' "$out" | sed -nE 's/.*[Pp]ublic[[:space:]_-]*[Kk]ey[[:space:]]*:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' | head -1)"
  # Newer Xray builds may label the public key as "Password:" in x25519 output.
  [[ -n "$pub" ]] || pub="$(printf '%s\n' "$out" | sed -nE 's/.*[Pp]assword[[:space:]]*:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' | head -1)"
  if [[ -n "$priv" && -n "$pub" ]]; then
    PRIVATE_KEY="$priv"
    PUBLIC_KEY="$pub"
    XRAY_BIN_PATH="$bin"
    return 0
  fi
  XRAY_KEYGEN_LAST_OUTPUT="$out"
  return 1
}


is_port "$V2_PORT" || { echo "ERROR: Invalid V2Ray/Xray port: $V2_PORT" >&2; exit 1; }
is_port "$XRAY_API_PORT" || { echo "ERROR: Invalid Xray API port: $XRAY_API_PORT" >&2; exit 1; }

mkdir -p "$DATA_DIR" "$APP_DIR" /usr/local/etc/xray

# Keep the same shared UUID when reinstalling/repairing this public/free VPN server.
UUID="${V2_UUID:-$(read_env V2_UUID '')}"
[[ -n "$UUID" ]] || UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="${V2_SHORT_ID:-$(read_env V2_SHORT_ID '')}"
[[ -n "$SHORT_ID" ]] || SHORT_ID="$(rand_hex 8)"

# Install Xray first, then generate/keep REALITY key pair.
echo "[V2Ray/Xray] Installing packages..."
apt_update_install curl unzip apache2 php libapache2-mod-php php-cli php-sqlite3 sqlite3 iptables iproute2 python3 ca-certificates openssl

systemctl stop xray 2>/dev/null || true
if port_used "$V2_PORT"; then
  echo "ERROR: V2Ray/Xray TCP port $V2_PORT is already in use. Choose another port." >&2
  exit 1
fi
if port_used "$XRAY_API_PORT"; then
  echo "ERROR: Xray local API port $XRAY_API_PORT is already in use. Choose another API port." >&2
  exit 1
fi

if ! find_xray_bin >/dev/null 2>&1; then
  install_or_update_xray
fi

XRAY_BIN_PATH="$(find_xray_bin || true)"
PRIVATE_KEY="${V2_PRIVATE_KEY:-$(read_env V2_PRIVATE_KEY '')}"
PUBLIC_KEY="${V2_PUBLIC_KEY:-$(read_env V2_PUBLIC_KEY '')}"
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  if ! generate_reality_keypair; then
    echo "[V2Ray/Xray] x25519 key generation failed. Updating Xray and trying again..."
    install_or_update_xray
    if ! generate_reality_keypair; then
      echo "ERROR: Could not generate Xray REALITY key pair." >&2
      echo "Tried Xray binary: $(find_xray_bin 2>/dev/null || echo 'not found')" >&2
      if [[ -n "${XRAY_KEYGEN_LAST_OUTPUT:-}" ]]; then
        echo "xray x25519 output:" >&2
        printf '%s\n' "$XRAY_KEYGEN_LAST_OUTPUT" >&2
      fi
      exit 1
    fi
  fi
fi
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { echo "ERROR: Empty Xray REALITY key pair." >&2; exit 1; }
XRAY_BIN_PATH="${XRAY_BIN_PATH:-$(find_xray_bin || echo xray)}"

cat >"$XRAY_CFG" <<EOFJSON
{
  "log": { "loglevel": "warning" },
  "api": {
    "tag": "api",
    "services": [ "StatsService" ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "statsUserOnline": true,
        "bufferSize": 4
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${V2_PORT},
      "protocol": "vless",
      "tag": "vless-reality",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "email": "${V2_EMAIL}",
            "level": 0,
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${V2_DEST}",
          "xver": 0,
          "serverNames": [ "${V2_SNI}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_API_PORT},
      "protocol": "dokodemo-door",
      "tag": "api-in",
      "settings": { "address": "127.0.0.1" }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": [ "api-in" ], "outboundTag": "api" }
    ]
  }
}
EOFJSON

"$XRAY_BIN_PATH" test -config "$XRAY_CFG" >/dev/null
iptables -C INPUT -p tcp --dport "$V2_PORT" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$V2_PORT" -j ACCEPT

cat >"$DATA_DIR/v2ray.env" <<EOFENV
V2_PORT=${V2_PORT}
V2_UUID=${UUID}
SERVER_ADDR=${SERVER_ADDR}
V2_SECURITY=reality
V2_NETWORK=tcp
V2_FLOW=xtls-rprx-vision
V2_SNI=${V2_SNI}
V2_DEST=${V2_DEST}
V2_SHORT_ID=${SHORT_ID}
V2_PUBLIC_KEY=${PUBLIC_KEY}
V2_PRIVATE_KEY=${PRIVATE_KEY}
V2_FINGERPRINT=chrome
V2_EMAIL=${V2_EMAIL}
XRAY_API_PORT=${XRAY_API_PORT}
EOFENV
chown www-data:www-data "$DATA_DIR/v2ray.env" 2>/dev/null || true
chmod 660 "$DATA_DIR/v2ray.env" 2>/dev/null || true

set_conf V2RAY 1
set_conf V2_PORT "$V2_PORT"
set_conf XRAY_API_PORT "$XRAY_API_PORT"

systemctl daemon-reload
systemctl enable xray apache2 >/dev/null 2>&1 || true
systemctl reload apache2 >/dev/null 2>&1 || systemctl restart apache2 || true
if [[ -x /usr/local/bin/vpn-control.sh ]]; then /usr/local/bin/vpn-control.sh refresh-firewall >/dev/null 2>&1 || true; fi
systemctl restart xray

chown -R root:www-data "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 755 {} \;
find "$APP_DIR" -type f -exec chmod 644 {} \;
chown -R www-data:www-data "$DATA_DIR"
chmod 775 "$DATA_DIR"
chmod 660 "$DATA_DIR/v2ray.env" 2>/dev/null || true

echo "[V2Ray/Xray] Done on port ${V2_PORT}"
echo "[V2Ray/Xray] Security: VLESS + TCP + REALITY + Vision"
echo "[V2Ray/Xray] Shared UUID: ${UUID}"
