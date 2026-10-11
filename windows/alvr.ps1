# ALVR streamer for a Quest plugged into the Mac (see README, VR). Run as SYSTEM
# via SSM after setup.ps1 and after SteamVR is installed:
#   -ClientIp  the Mac's Tailscale IP (`tailscale ip -4` on the Mac)
# ALVR connects out to the Mac on 9943/9944; `gpc vr` relays those over USB.
param(
  [Parameter(Mandatory)] [string] $ClientIp
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The Quest app (alvr_client_android.apk) must be the same version
$AlvrVersion = '20.14.1'
$AlvrSha256 = '6FBB85432822E9E3162D29B2919CD843BD9805262AEF0C4797FFEC7C57654A83'

Get-Process 'ALVR Dashboard' -ErrorAction SilentlyContinue | Stop-Process -Force
if (Test-Path C:\ALVR) { Remove-Item C:\ALVR -Recurse -Force }
Invoke-WebRequest "https://github.com/alvr-org/ALVR/releases/download/v$AlvrVersion/alvr_streamer_windows.zip" -OutFile C:\gaming\alvr.zip
if ((Get-FileHash C:\gaming\alvr.zip -Algorithm SHA256).Hash -ne $AlvrSha256) { throw 'ALVR zip hash mismatch' }
Expand-Archive C:\gaming\alvr.zip C:\ALVR # no top-level folder in the zip

# Partial session; ALVR fills in the rest from its defaults on first start.
# adb only forwards TCP, so the stream runs over TCP. Discovery is UDP
# broadcast and can't cross Tailscale, so the Mac is a trusted manual client.
@"
{
  "client_connections": {
    "quest-via-mac": {
      "display_name": "Quest 3 (USB via Mac)",
      "current_ip": null,
      "manual_ips": ["$ClientIp"],
      "trusted": true,
      "connection_state": "Disconnected"
    }
  },
  "session_settings": {
    "video": { "preferred_codec": { "variant": "Hevc" } },
    "connection": { "stream_protocol": { "variant": "Tcp" }, "client_discovery": { "enabled": false } },
    "extra": { "steamvr_launcher": { "open_close_steamvr_with_dashboard": true }, "open_setup_wizard": false }
  }
}
"@ | Set-Content C:\ALVR\session.json

# The dashboard needs the desktop session; `gpc vr` starts this task over SSM.
# It registers its SteamVR driver itself when it launches SteamVR.
$action = New-ScheduledTaskAction -Execute 'C:\ALVR\ALVR Dashboard.exe' -WorkingDirectory C:\ALVR
$principal = New-ScheduledTaskPrincipal -UserId Administrator -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName ALVR -Action $action -Principal $principal -Settings $settings -Force | Out-Null

Write-Output "ALVR $AlvrVersion installed for client $ClientIp"
