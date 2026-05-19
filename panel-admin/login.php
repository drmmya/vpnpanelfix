<?php
require __DIR__.'/config.php';
if(!empty($_SESSION['admin_user'])){ header('Location: index.php'); exit; }
$err='';
$ip=client_ip();
$key='login_fail_'.$ip;
$lockKey='login_lock_'.$ip;
$lockedUntil=(int)($_SESSION[$lockKey] ?? 0);
if($lockedUntil > time()){
  $err='Too many failed login attempts. Try again after '.date('H:i:s',$lockedUntil).' UTC.';
} elseif($_SERVER['REQUEST_METHOD']==='POST'){
  if(!csrf_check()){
    $err='Invalid security token. Refresh and try again.';
  } elseif(admin_login(trim($_POST['username'] ?? ''), $_POST['password'] ?? '')){
    $_SESSION['admin_user']=trim($_POST['username']);
    $_SESSION[$key]=0;
    unset($_SESSION[$lockKey]);
    session_regenerate_id(true);
    header('Location: index.php'); exit;
  } else {
    $_SESSION[$key]=(int)($_SESSION[$key] ?? 0)+1;
    if($_SESSION[$key] >= 5){ $_SESSION[$lockKey]=time()+300; }
    $err='Invalid username or password';
  }
}
?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VPN Panel Login</title><link rel="stylesheet" href="style.css"></head><body><div class="layout" style="max-width:680px;min-height:100vh;align-items:center;justify-content:center"><div class="card" style="width:100%"><div class="brand">VPN Panel</div><div class="sub">Login with admin account</div><br><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?><form method="post"><?=csrf_field()?><label>Username</label><input name="username" autocomplete="username" required><br><br><label>Password</label><input type="password" name="password" autocomplete="current-password" required><br><br><button class="btn" type="submit">Login</button></form></div></div></body></html>
