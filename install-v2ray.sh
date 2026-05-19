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
UUID="${V2_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
CONF_FILE="/etc/vpn-protocols.conf"
SERVER_ADDR="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
V2_SNI="${V2_SNI:-www.microsoft.com}"
V2_REALITY_DEST="${V2_REALITY_DEST:-${V2_SNI}:443}"
V2_FLOW="xtls-rprx-vision"
V2_FP="chrome"

is_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
set_conf(){ local k="$1" v="$2"; touch "$CONF_FILE"; if grep -qE "^${k}=" "$CONF_FILE"; then sed -i "s|^${k}=.*|${k}=${v}|" "$CONF_FILE"; else echo "${k}=${v}" >> "$CONF_FILE"; fi; chmod 644 "$CONF_FILE"; }
port_used(){ local port="$1"; ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; }
find_xray(){
  if command -v xray >/dev/null 2>&1; then command -v xray; return 0; fi
  if [[ -x /usr/local/bin/xray ]]; then echo /usr/local/bin/xray; return 0; fi
  if [[ -x /usr/bin/xray ]]; then echo /usr/bin/xray; return 0; fi
  return 1
}
install_xray_core(){
  echo "[V2Ray/Xray] Installing/updating Xray core..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" install >/dev/null
}
parse_x25519_output(){
  local out="$1"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*(PrivateKey|Private key)[[:space:]]*:[[:space:]]*([^[:space:]]+).*/\2/p' | head -n1)"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*(Password \(PublicKey\)|Password|PublicKey|Public key)[[:space:]]*:[[:space:]]*([^[:space:]]+).*/\2/p' | head -n1)"
  [[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" ]]
}
generate_reality_keys(){
  local out=""
  XRAY_BIN="$(find_xray || true)"
  [[ -n "$XRAY_BIN" ]] || return 1
  out="$($XRAY_BIN x25519 2>&1 || true)"
  if parse_x25519_output "$out"; then return 0; fi
  echo "[V2Ray/Xray] x25519 key generation failed. Updating Xray and trying again..."
  install_xray_core
  XRAY_BIN="$(find_xray || true)"
  [[ -n "$XRAY_BIN" ]] || return 1
  out="$($XRAY_BIN x25519 2>&1 || true)"
  if parse_x25519_output "$out"; then return 0; fi
  echo "ERROR: Could not generate Xray REALITY key pair." >&2
  echo "Tried Xray binary: ${XRAY_BIN:-not-found}" >&2
  echo "xray x25519 output:" >&2
  printf '%s\n' "$out" >&2
  return 1
}
random_short_id(){
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 8; else tr -dc 'a-f0-9' </dev/urandom | head -c 16; fi
}

is_port "$V2_PORT" || { echo "ERROR: Invalid V2Ray/Xray port: $V2_PORT" >&2; exit 1; }

echo "[V2Ray/Xray] Installing packages..."
apt_update_install curl unzip apache2 php libapache2-mod-php php-cli php-sqlite3 sqlite3 iptables iproute2 python3 ca-certificates openssl

systemctl stop xray 2>/dev/null || true
if port_used "$V2_PORT"; then
  echo "ERROR: V2Ray/Xray TCP port $V2_PORT is already in use. Choose another port." >&2
  exit 1
fi

if ! find_xray >/dev/null 2>&1; then
  install_xray_core
fi
XRAY_BIN="$(find_xray || true)"
[[ -n "$XRAY_BIN" ]] || { echo "ERROR: xray binary not found after install." >&2; exit 1; }

generate_reality_keys
SHORT_ID="${V2_SHORT_ID:-$(random_short_id)}"

mkdir -p /usr/local/etc/xray "$DATA_DIR" "$APP_DIR"

cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${V2_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "email": "shared@asiafastvpn",
            "flow": "${V2_FLOW}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${V2_REALITY_DEST}",
          "xver": 0,
          "serverNames": [ "${V2_SNI}" ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

iptables -C INPUT -p tcp --dport "$V2_PORT" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$V2_PORT" -j ACCEPT
cat >"$DATA_DIR/v2ray.env" <<EOF
V2_PORT=${V2_PORT}
V2_UUID=${UUID}
SERVER_ADDR=${SERVER_ADDR}
V2_SECURITY=reality
V2_FLOW=${V2_FLOW}
V2_FP=${V2_FP}
V2_SNI=${V2_SNI}
V2_REALITY_DEST=${V2_REALITY_DEST}
V2_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
V2_SHORT_ID=${SHORT_ID}
EOF
chown www-data:www-data "$DATA_DIR/v2ray.env" 2>/dev/null || true
chmod 664 "$DATA_DIR/v2ray.env" 2>/dev/null || true

cat >"$APP_DIR/v2ray.php" <<'PHP'
<?php
require __DIR__.'/config.php'; require_login();
$env=[]; $f=DATA_DIR.'/v2ray.env'; if(is_file($f)){ foreach(file($f,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){ if(strpos($line,'=')!==false){[$k,$v]=explode('=',$line,2); $env[$k]=$v; } } }
$port=(int)($env['V2_PORT']??cfgv('V2_PORT','4443'));
$uuid=$env['V2_UUID']??'';
$host=$env['SERVER_ADDR']??($_SERVER['SERVER_ADDR']??'SERVER_IP');
$security=$env['V2_SECURITY']??'none';
$sni=$env['V2_SNI']??'www.microsoft.com';
$pbk=$env['V2_PUBLIC_KEY']??'';
$sid=$env['V2_SHORT_ID']??'';
$flow=$env['V2_FLOW']??'xtls-rprx-vision';
$fp=$env['V2_FP']??'chrome';
if($security==='reality' && $pbk!==''){
  $link='vless://'.$uuid.'@'.$host.':'.$port.'?encryption=none&security=reality&type=tcp&fp='.rawurlencode($fp).'&sni='.rawurlencode($sni).'&pbk='.rawurlencode($pbk).'&sid='.rawurlencode($sid).'&flow='.rawurlencode($flow).'#VPN-Panel-V2Ray';
  $manual="Address: {$host}\nPort: {$port}\nUUID: {$uuid}\nProtocol: VLESS\nNetwork: TCP\nSecurity: REALITY\nEncryption: none\nFlow: {$flow}\nSNI: {$sni}\nFingerprint: {$fp}\nPublicKey: {$pbk}\nShortID: {$sid}";
}else{
  $link='vless://'.$uuid.'@'.$host.':'.$port.'?encryption=none&security=none&type=tcp#VPN-Panel-V2Ray';
  $manual="Address: {$host}\nPort: {$port}\nUUID: {$uuid}\nProtocol: VLESS\nNetwork: TCP\nSecurity: None\nEncryption: None";
}
$active=trim(shell_exec("ss -Htn state established '( sport = :$port )' 2>/dev/null | awk '{print \$5}' | cut -d: -f1 | sort -u | wc -l"));
render_header('V2Ray Panel'); ?>
<div class="panel-banner"><div class="toolbar"><div><h2 class="section-title">V2Ray / Xray Live Panel</h2><div class="small"><span class="live-dot"></span> Port, active IP and config link auto-refresh every 5 seconds.</div></div><span id="v2SvcBadge" class="badge">LIVE</span></div></div>
<div class="grid"><div class="card soft-card"><div class="muted">Port</div><div class="kpi" id="v2Port"><?=esc($port)?></div></div><div class="card soft-card"><div class="muted">Active IPs</div><div class="kpi" id="v2Active"><?=esc($active?:'0')?></div></div></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">V2Ray / Xray VLESS Link</h2><div class="copy-row"><div class="code" id="v2Link"><?=esc($link)?></div><button class="btn copy-btn" data-copy="<?=esc($link)?>" id="v2CopyLink" title="Copy VLESS link">📋</button></div></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">Manual config</h2><div class="copy-row"><div class="code" id="v2Manual"><?=esc($manual)?></div><button class="btn copy-btn" data-copy="<?=esc($manual)?>" id="v2CopyManual" title="Copy manual config">📋</button></div></div>
<script>
async function refreshV2Ray(){try{const r=await fetch('api_status.php?proto=v2ray&_='+Date.now(),{cache:'no-store'});const d=await r.json();if(!d.ok)return;document.getElementById('v2Port').textContent=d.port;document.getElementById('v2Active').textContent=d.active_ips||'0';document.getElementById('v2Link').textContent=d.link;document.getElementById('v2Manual').textContent=d.manual;document.getElementById('v2CopyLink').setAttribute('data-copy',d.link);document.getElementById('v2CopyManual').setAttribute('data-copy',d.manual);const b=document.getElementById('v2SvcBadge');b.className='badge '+(d.running?'green':'red');b.textContent=d.running?'RUNNING':'STOPPED';}catch(e){}}
refreshV2Ray();setInterval(refreshV2Ray,5000);
</script>
<?php render_footer(); ?>

PHP

set_conf V2RAY 1
set_conf V2_PORT "$V2_PORT"
set_conf V2_SECURITY reality
systemctl daemon-reload
systemctl enable xray apache2 >/dev/null 2>&1 || true
systemctl reload apache2 >/dev/null 2>&1 || systemctl restart apache2 || true
if [[ -x /usr/local/bin/vpn-control.sh ]]; then /usr/local/bin/vpn-control.sh refresh-firewall >/dev/null 2>&1 || true; fi
if ! systemctl restart xray; then
  echo "ERROR: Xray service failed to start. Last logs:" >&2
  journalctl -u xray -n 60 --no-pager >&2 || true
  exit 1
fi
chown -R root:www-data "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 755 {} \;
find "$APP_DIR" -type f -exec chmod 644 {} \;
chown -R www-data:www-data "$DATA_DIR"
chmod -R 775 "$DATA_DIR"
echo "[V2Ray/Xray] Done on port ${V2_PORT} with VLESS REALITY"
