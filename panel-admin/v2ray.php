<?php
require __DIR__.'/config.php'; require_login();
function v2ray_env_local(){
  $env=[]; $f=DATA_DIR.'/v2ray.env';
  if(is_file($f)){
    foreach(file($f,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){
      if(strpos($line,'=')!==false){[$k,$v]=explode('=',$line,2); $env[$k]=$v; }
    }
  }
  return $env;
}
function v2ray_link_local($env){
  $port=(int)($env['V2_PORT']??cfgv('V2_PORT','4443'));
  $uuid=$env['V2_UUID']??'';
  $host=$env['SERVER_ADDR']??($_SERVER['SERVER_ADDR']??'SERVER_IP');
  if(($env['V2_SECURITY']??'reality')==='reality'){
    return 'vless://'.$uuid.'@'.$host.':'.$port.'?encryption=none&security=reality&type=tcp&sni='.rawurlencode($env['V2_SNI']??'www.microsoft.com').'&fp='.rawurlencode($env['V2_FINGERPRINT']??'chrome').'&pbk='.rawurlencode($env['V2_PUBLIC_KEY']??'').'&sid='.rawurlencode($env['V2_SHORT_ID']??'').'&flow='.rawurlencode($env['V2_FLOW']??'xtls-rprx-vision').'#AsiaFastVPN-REALITY';
  }
  return 'vless://'.$uuid.'@'.$host.':'.$port.'?encryption=none&security=none&type=tcp#AsiaFastVPN-V2Ray';
}
function v2ray_manual_local($env){
  $port=(int)($env['V2_PORT']??cfgv('V2_PORT','4443'));
  $uuid=$env['V2_UUID']??'';
  $host=$env['SERVER_ADDR']??($_SERVER['SERVER_ADDR']??'SERVER_IP');
  if(($env['V2_SECURITY']??'reality')==='reality'){
    return "Address: {$host}\nPort: {$port}\nUUID: {$uuid}\nProtocol: VLESS\nNetwork: TCP\nSecurity: REALITY\nFlow: ".($env['V2_FLOW']??'xtls-rprx-vision')."\nSNI: ".($env['V2_SNI']??'www.microsoft.com')."\nFingerprint: ".($env['V2_FINGERPRINT']??'chrome')."\nPublic Key: ".($env['V2_PUBLIC_KEY']??'')."\nShort ID: ".($env['V2_SHORT_ID']??'');
  }
  return "Address: {$host}\nPort: {$port}\nUUID: {$uuid}\nProtocol: VLESS\nNetwork: TCP\nSecurity: None\nEncryption: None";
}
$env=v2ray_env_local();
$port=(int)($env['V2_PORT']??cfgv('V2_PORT','4443'));
$link=v2ray_link_local($env);
$manual=v2ray_manual_local($env);
$security=$env['V2_SECURITY']??'reality';
render_header('V2Ray Panel');
?>
<div class="panel-banner">
  <div class="toolbar">
    <div>
      <h2 class="section-title">V2Ray / Xray REALITY Live Panel</h2>
      <div class="small"><span class="live-dot"></span> Shared public/free VPN config. Link, active IPs and traffic refresh every 5 seconds.</div>
    </div>
    <span id="v2SvcBadge" class="badge">LIVE</span>
  </div>
</div>
<div class="grid">
  <div class="card soft-card"><div class="muted">Port</div><div class="kpi" id="v2Port"><?=esc($port)?></div></div>
  <div class="card soft-card"><div class="muted">Security</div><div class="kpi small-kpi" id="v2Security"><?=esc(strtoupper($security))?></div></div>
  <div class="card soft-card"><div class="muted">Active IPs</div><div class="kpi" id="v2Active">0</div><div class="small" id="v2Source">Checking...</div></div>
  <div class="card soft-card"><div class="muted">Total Traffic</div><div class="kpi small-kpi" id="v2Traffic">-</div></div>
</div>
<div class="card" style="margin-top:18px">
  <h2 class="section-title">Secure VLESS REALITY Link</h2>
  <div class="copy-row"><div class="code" id="v2Link"><?=esc($link)?></div><button class="btn copy-btn" data-copy="<?=esc($link)?>" id="v2CopyLink" title="Copy VLESS link">📋</button></div>
</div>
<div class="card" style="margin-top:18px">
  <h2 class="section-title">Manual config</h2>
  <div class="copy-row"><div class="code" id="v2Manual"><?=esc($manual)?></div><button class="btn copy-btn" data-copy="<?=esc($manual)?>" id="v2CopyManual" title="Copy manual config">📋</button></div>
</div>
<div class="card" style="margin-top:18px">
  <div class="toolbar"><div><h2 class="section-title">Realtime Connected IPs</h2><div class="small">VLESS shared config can show connected IP/device count. It cannot show exact app package/version unless the app sends a separate heartbeat API.</div></div></div>
  <table><thead><tr><th>#</th><th>Client IP</th></tr></thead><tbody id="v2IpRows"><tr><td colspan="2" class="empty">No active V2Ray client.</td></tr></tbody></table>
</div>
<script>
function rowsFromIps(ips){
  if(!ips || !ips.length) return '<tr><td colspan="2" class="empty">No active V2Ray client.</td></tr>';
  return ips.map((ip,i)=>'<tr><td>'+(i+1)+'</td><td><strong>'+String(ip).replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]))+'</strong></td></tr>').join('');
}
async function refreshV2Ray(){try{const r=await fetch('api_status.php?proto=v2ray&_='+Date.now(),{cache:'no-store'});const d=await r.json();if(!d.ok)return;document.getElementById('v2Port').textContent=d.port;document.getElementById('v2Security').textContent=(d.security||'reality').toUpperCase();document.getElementById('v2Active').textContent=d.active_ips||'0';document.getElementById('v2Source').textContent='Source: '+(d.active_source||'socket-fallback');document.getElementById('v2Traffic').textContent=d.traffic_human?d.traffic_human.total:'-';document.getElementById('v2Link').textContent=d.link;document.getElementById('v2Manual').textContent=d.manual;document.getElementById('v2CopyLink').setAttribute('data-copy',d.link);document.getElementById('v2CopyManual').setAttribute('data-copy',d.manual);document.getElementById('v2IpRows').innerHTML=rowsFromIps(d.active_ip_list||[]);const b=document.getElementById('v2SvcBadge');b.className='badge '+(d.running?'green':'red');b.textContent=d.running?'RUNNING':'STOPPED';}catch(e){}}
refreshV2Ray();setInterval(refreshV2Ray,5000);
</script>
<?php render_footer(); ?>
