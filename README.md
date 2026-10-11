# cloud-gaming

A Windows GPU instance on AWS, streamed to the MacBook with Moonlight over Tailscale. Built for DCS, Falcon BMS and Ready or Not, and paid for with AWS Activate credits (expire 2027-07-31).

## Current machine

| | |
|---|---|
| Instance | `i-038761e72015ad082` (`gaming-pc`), us-east-2a |
| Type | g6e.4xlarge: NVIDIA L40S 48GB, 16 vCPU (EPYC 7R13), 128GB RAM |
| Disk | 1250GB gp3, 16000 IOPS, 1000MB/s, `DeleteOnTermination=false` |
| OS | Windows Server 2022 |
| Network | Tailscale `gaming-pc`; Elastic IP |
| AWS profile | `m5mbp` (`aws login --profile m5mbp --remote`) |

`gpc start` tries instance types in order (`TYPES` in `gpc`) and keeps the first with capacity: g6e.4xlarge first, then the Blackwell g7e/g7 types, then smaller and older GPUs. It only changes the type when the instance is stopped.

## Daily use

`gpc` (in dotfiles, `~/.local/bin/gpc`):

```sh
gpc start         # boot, wait for Tailscale, open Moonlight
gpc stop          # shut down (the disk still bills)
gpc status
gpc ui            # Apollo web UI; copies the password to the clipboard
gpc rdp-password  # Windows Administrator password
gpc vr            # stream SteamVR to a Quest plugged into the Mac (see VR)
```

The instance stops itself after 30 min with no streaming, downloading, disk writes or CPU load (`windows/idle.ps1`), with a CloudWatch backup alarm that stops it after 6h of near-zero NetworkOut. Long installs (for example DCS unpacking at about 50MB/s with no network traffic) count as busy.

## Moonlight settings

Stored in `~/Library/Preferences/com.moonlight-stream.Moonlight.plist`. Don't commit it, because it holds the pairing key.

| Setting | Value | plist key |
|---|---|---|
| Resolution | 2560×1600 (16:10; 3024×1890 needs ~100 Mbps and a gigabit link) | `width`, `height` |
| FPS | 120 | `fps` |
| Bitrate | 60 Mbps, no auto-adjust | `bitrate`, `autoadjustbitrate` |
| Codec | AV1 | `videocfg = 4` |
| Window | Borderless fullscreen | `windowmode = 1` |
| V-Sync, frame pacing | Off (each costs about a frame of latency) | `vsync`, `framepacing` |
| Mouse | Game (raw relative) mode, not "optimize for remote desktop"; ⌃⌥⇧M toggles mid-stream | `mouseacceleration = false` |

Quit Moonlight before editing the plist, or it overwrites the changes on exit. After changing resolution, use Quit App on Desktop in Moonlight; a plain reconnect resumes the old session at the old size.

## VR

ALVR streams SteamVR to a Quest 3 plugged into the Mac by USB-C, so the headset doesn't depend on the local Wi-Fi:

```
gaming PC (ALVR streamer) ──Tailscale──▶ Mac (socat) ──USB (adb forward)──▶ Quest (ALVR client)
```

- `windows/alvr.ps1` installs the ALVR streamer in `C:\ALVR` with the Mac's Tailscale IP as a trusted client, the stream over TCP (adb only forwards TCP) and HEVC, plus a scheduled task `ALVR` that runs the dashboard in the desktop session. The dashboard opens and closes SteamVR with itself.
- `gpc vr` checks the headset is connected, installs the matching ALVR app from `~/.local/share/gpc/alvr_client_android-v<version>.apk`, starts the PC if needed, starts ALVR over SSM, forwards 9943 (control) and 9944 (stream) into the headset, and relays them from the Mac's Tailscale IP. Ctrl-C closes ALVR and SteamVR; the PC keeps running.
- One-time setup: enable developer mode on the Quest (Meta Horizon app), install SteamVR on the PC, run `alvr.ps1 -ClientIp <Mac Tailscale IP>` via SSM, `brew install socat android-platform-tools`, and download `alvr_client_android.apk` from the same ALVR release. Accept the USB debugging prompt in the headset on first connect.
- ALVR's streamer and the Quest app must be the same version; update `$AlvrVersion` in `alvr.ps1` and the APK in `gpc` together.
- Over TCP, packet loss stalls the stream instead of dropping a frame. If it hitches, lower the bitrate in the ALVR dashboard.

## Rebuild from scratch

1. `./provision.sh`: creates the IAM role, key pair (`~/.ssh/cloud-gaming.pem`), security group, instance, EIP and alarm. If the instance type has no capacity, retry with `AZ=us-east-1c` or another type.
2. Wait about 5 min for Windows to finish booting and for SSM to report the instance as Online.
3. `./bootstrap.sh <instance-id>`: runs `windows/setup.ps1`, which installs the NVIDIA gaming driver and license, Steam, Apollo, ViGEmBus, VB-Cable, Tailscale, the idle shutdown and auto-logon, then reboots.
4. Join the tailnet: run `tailscale up --unattended --hostname gaming-pc` on the instance via SSM and open the login URL it prints.
5. Update `IID` in `gpc`, then pair Moonlight (add `gaming-pc`, enter the PIN in the Apollo UI's PIN tab).
6. Sign in to Steam and install games.

Restoring from a snapshot (see Backups) skips steps 3–6.

## Backups

A Data Lifecycle Manager policy (`policy-072f11f3cabae3343`) snapshots the C: volume (tag `Name=gaming-pc-c`) every Monday at 09:00 UTC and keeps the last 4. Snapshots are incremental, about $0.05/GB-month for used blocks.

To restore: create a volume from a snapshot in the instance's AZ, stop the instance, detach the current root volume, attach the restored one as `/dev/sda1`, and start. Games, saves and keybinds all come back.

## Gotchas

- **ViGEmBus refuses Windows Server.** Its MSI LaunchCondition blocks Server, and its updater scheduled task fails under SYSTEM. `setup.ps1` captures the MSI mid-install and reruns the installer with a transform that drops both.
- **Software encoding after a cold boot.** Apollo probes encoders once when it starts. If that happens before the NVIDIA driver is up, it only sees the Microsoft Basic Render Driver, settles on libx264 and advertises H.264 only, and Moonlight falls back from AV1 to H.264. `gpc start` waits until Apollo advertises HEVC and otherwise restarts it through the web API (`/api/restart`).
- **Empty stream window.** The NVIDIA driver exposes its own display, so Apollo captured an empty secondary screen. Fixed with `dd_configuration_option = ensure_only_display`.
- **No audio device on EC2.** Steam no longer ships Steam Streaming Speakers in the client. Apollo installs them on the first stream; VB-Cable is installed so a playback device always exists.
- **Controller not detected in Xbox mode.** Windows Server lacks the Xbox 360 driver, so the virtual pad shows error 28 (no driver). `setup.ps1` installs Microsoft's `xusb21` from the Update Catalog.
- **Blurry, oversized UI.** The NVIDIA driver's own display is fixed at 1280×800 and Apollo can't change its mode (`failed to set display mode`). `headless_mode = enabled` makes every session use Apollo's virtual display at the client's resolution.
- **Apollo web UI 403.** By default it only allows LAN origins; `origin_web_ui_allowed = wan` is safe because only the tailnet can reach it.
- **Public ports.** Only UDP 41641 (Tailscale direct) and the BMS installer's BitTorrent ports (TCP 36881-36999, UDP 6881-6999) are open. Moonlight, Apollo and RDP are reachable only over Tailscale.
- **BMS torrents stall at 0 peers** without those inbound ports, since the few seeders of add-ons like 16K terrain are also unreachable. A partial download (0-byte `.dds` in `Photoreal\16K`) crashes BMS in `ResourceManager::onCreateDevice` when a mission loads; rename the folder until it completes.
- **.NET 3.5** can't be added through Windows Features on Server; `setup.ps1` installs it with `Install-WindowsFeature`.
- **Reddit blocks AWS IPs.** Browse on the Mac instead.
- **Slow game installs.** Defender real-time scanning throttled DCS unpacking, so game folders and updaters are excluded. Downloads from Steam reach about 2.6 Gbps; the disk was the bottleneck at 600MB/s.

## Costs (on-demand, from credits)

- Instance: $3.74/hr (Windows included)
- Egress: $0.09/GB, roughly $5–7/hr total at 80–150 Mbps
- Disk + EIP: about $245/mo, even when stopped (1250GB plus provisioned IOPS and throughput)

## Secrets (never in this repo)

- `~/.ssh/cloud-gaming.pem`: decrypts the Windows password
- Keychain `gaming-pc-windows`, `gaming-pc-apollo-ui`
- Moonlight plist (pairing key); Apollo `sunshine_state.json` on the instance
