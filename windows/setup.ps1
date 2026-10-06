# Windows setup for the cloud gaming PC. Run as SYSTEM via SSM (see README),
# then reboot. Secrets are passed in, never stored here:
#   -ApolloPassword  Apollo web UI password (user "admin")
#   -WindowsPassword Administrator password, for auto-logon
param(
  [Parameter(Mandatory)] [string] $ApolloPassword,
  [Parameter(Mandatory)] [string] $WindowsPassword
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force C:\gaming | Out-Null
Start-Transcript -Append C:\gaming\setup.log

$ApolloVersion = '0.4.6'
$Apollo = 'C:\Program Files\Apollo'

# --- NVIDIA cloud gaming driver + license -----------------------------------
$drv = Get-S3Object -BucketName nvidia-gaming -KeyPrefix windows/latest -Region us-east-1 |
  Where-Object { $_.Key -like '*server2022*.exe' } | Select-Object -First 1
Copy-S3Object -BucketName nvidia-gaming -Key $drv.Key -LocalFile C:\gaming\nvidia.exe -Region us-east-1 | Out-Null
Start-Process C:\gaming\nvidia.exe -ArgumentList '-s', '-noreboot', '-clean' -Wait
New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global' -Name vGamingMarketplace -PropertyType DWord -Value 2 -Force | Out-Null
# Cert for driver 591.59+; older drivers need an older cert (see AWS "Install NVIDIA gaming drivers" docs)
Invoke-WebRequest -Uri 'https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCert_2026_03_02.cert' -OutFile "$Env:PUBLIC\Documents\GridSwCert.txt"

# --- Windows Server tweaks for gaming ----------------------------------------
Set-Service Audiosrv -StartupType Automatic
Set-Service AudioEndpointBuilder -StartupType Automatic
Install-WindowsFeature Server-Media-Foundation | Out-Null
# Some game installers/launchers need .NET 3.5; the Windows Features dialog can't add it on Server
Install-WindowsFeature NET-Framework-Core | Out-Null
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c # High performance
powercfg /change monitor-timeout-ac 0
Disable-ScheduledTask -TaskName ServerManager -TaskPath '\Microsoft\Windows\Server Manager\' -ErrorAction SilentlyContinue | Out-Null
reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' /v DisableCAD /t REG_DWORD /d 1 /f | Out-Null
# Defender scanning every written file throttles game installs/unpacking
Add-MpPreference -ExclusionPath 'C:\Program Files (x86)\Steam', 'C:\Program Files\Eagle Dynamics', 'C:\Falcon BMS 4.38', 'C:\Falcon BMS', 'C:\GOG Games', 'C:\Users\Administrator\Saved Games', 'C:\gaming'
Add-MpPreference -ExclusionProcess 'DCS_updater.exe', 'DCS.exe', 'steam.exe', 'steamservice.exe', 'steamwebhelper.exe', 'Falcon BMS.exe', 'qbittorrent.exe'

# --- Steam ---------------------------------------------------------------------
Invoke-WebRequest -Uri 'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe' -OutFile C:\gaming\SteamSetup.exe
Start-Process C:\gaming\SteamSetup.exe -ArgumentList '/S' -Wait

# --- Apollo (Sunshine fork with a built-in virtual display, SudoVDA) ---------
Invoke-WebRequest -Uri "https://github.com/ClassicOldSong/Apollo/releases/download/v$ApolloVersion/Apollo-$ApolloVersion.exe" -OutFile C:\gaming\Apollo.exe
Start-Process C:\gaming\Apollo.exe -ArgumentList '/S' -Wait
& "$Apollo\sunshine.exe" --creds admin $ApolloPassword
@(
  'origin_web_ui_allowed = wan'           # web UI is only reachable over Tailscale anyway
  'sunshine_name = gaming-pc'
  'dd_configuration_option = ensure_only_display' # stream the virtual display, not an empty second screen
  'gamepad = x360'                        # Xbox controller so games (BMS) use XInput, even for a DS4-mode pad
) | Add-Content "$Apollo\config\sunshine.conf"
New-NetFirewallRule -DisplayName 'Apollo TCP' -Direction Inbound -Protocol TCP -LocalPort 47984, 47989, 47990, 48010 -Action Allow | Out-Null
New-NetFirewallRule -DisplayName 'Apollo UDP' -Direction Inbound -Protocol UDP -LocalPort 47998-48010 -Action Allow | Out-Null
# BMS installer's aria2 torrents (listen-port 36881-36999, DHT 6881-6999): without inbound, niche torrents find no peers
New-NetFirewallRule -DisplayName 'BMS BitTorrent TCP' -Direction Inbound -Protocol TCP -LocalPort 36881-36999 -Action Allow | Out-Null
New-NetFirewallRule -DisplayName 'BMS BitTorrent UDP' -Direction Inbound -Protocol UDP -LocalPort 6881-6999 -Action Allow | Out-Null

# --- ViGEmBus (virtual gamepad) ------------------------------------------------
# The bundled installer's MSI has a LaunchCondition that rejects Windows Server,
# and its updater scheduled task fails when run as SYSTEM (rolling back the
# install). Grab the MSI mid-install, build a transform that drops both, and
# rerun the installer with it.
$vigemExe = "$Apollo\scripts\vigembus_installer.exe"
$cache = 'C:\ProgramData\Nefarius Software Solutions'
$cap = 'C:\gaming\vgcap'
$p = Start-Process $vigemExe -ArgumentList '/quiet', '/norestart' -PassThru
while (-not $p.HasExited) {
  if (Test-Path $cache) { robocopy $cache $cap /E /R:0 /W:0 /NFL /NDL /NJH /NJS /NP | Out-Null }
}
$orig = Get-ChildItem $cap -Recurse -Filter ViGEmBus.x64.msi | Select-Object -First 1 -ExpandProperty FullName
Copy-Item $orig C:\gaming\vg_mod.msi -Force
$wi = New-Object -ComObject WindowsInstaller.Installer
$db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @('C:\gaming\vg_mod.msi', 1))
function Invoke-MsiSql($sql) {
  $v = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($sql))
  [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null)
  [void]$v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)
}
Invoke-MsiSql 'DELETE FROM LaunchCondition'
foreach ($a in 'AI_ScheduleTasks2', 'AI_ProcessTasks2', 'AI_RollbackTasks2') {
  Invoke-MsiSql "DELETE FROM InstallExecuteSequence WHERE Action = '$a'"
}
[void]$db.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $db, $null)
$o = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($orig, 0))
[void]$db.GetType().InvokeMember('GenerateTransform', 'InvokeMethod', $null, $db, @($o, 'C:\gaming\vigem.mst'))
[void]$db.GetType().InvokeMember('CreateTransformSummaryInfo', 'InvokeMethod', $null, $db, @($o, 'C:\gaming\vigem.mst', 0, 0))
$p = Start-Process $vigemExe -ArgumentList '/quiet', '/norestart', 'TRANSFORMS="C:\gaming\vigem.mst"' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "ViGEmBus install failed: $($p.ExitCode)" }

# --- Audio ---------------------------------------------------------------------
# EC2 has no audio device. Apollo installs Steam Streaming Speakers on the first
# stream; VB-Cable makes sure a default playback device exists before that.
Invoke-WebRequest https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip -OutFile C:\gaming\vbcable.zip
Expand-Archive C:\gaming\vbcable.zip C:\gaming\vbcable -Force
$cat = Get-ChildItem C:\gaming\vbcable -Filter *64*.cat | Select-Object -First 1
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
$store.Open('ReadWrite'); $store.Add((Get-AuthenticodeSignature $cat.FullName).SignerCertificate); $store.Close()
Start-Process C:\gaming\vbcable\VBCABLE_Setup_x64.exe -ArgumentList '-i', '-h' -Wait

# --- Tailscale -----------------------------------------------------------------
# After setup, run `tailscale up --unattended --hostname gaming-pc` and open the
# printed login URL to add the machine to the tailnet.
Invoke-WebRequest https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi -OutFile C:\gaming\tailscale.msi
Start-Process msiexec.exe -ArgumentList '/i', 'C:\gaming\tailscale.msi', '/qn', 'TS_UNATTENDEDMODE=always', 'TS_NOLAUNCH=1' -Wait

# --- Idle shutdown ---------------------------------------------------------------
Copy-Item "$PSScriptRoot\idle.ps1" C:\gaming\idle.ps1 -Force
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\gaming\idle.ps1'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName GamingIdleShutdown -Action $action -Trigger $trigger -User SYSTEM -RunLevel Highest -Force | Out-Null
Register-ScheduledTask -TaskName GamingIdleReset -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c del C:\gaming\idle.json') `
  -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -Force | Out-Null

# --- Auto-logon (Apollo needs a desktop session) ----------------------------------
Invoke-WebRequest -Uri 'https://live.sysinternals.com/Autologon64.exe' -OutFile C:\gaming\Autologon64.exe
Start-Process C:\gaming\Autologon64.exe -ArgumentList '/accepteula', 'Administrator', '.', $WindowsPassword -Wait

# --- Display ---------------------------------------------------------------------
# Disable EC2's basic display adapter so games render on the NVIDIA GPU
Get-PnpDevice -Class Display -FriendlyName 'Microsoft Basic Display Adapter' -Status OK | Disable-PnpDevice -Confirm:$false

Write-Output 'SETUP DONE, rebooting'
Stop-Transcript
Restart-Computer -Force
