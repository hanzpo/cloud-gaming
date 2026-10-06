# cloud-gaming

A Windows GPU instance on AWS, streamed to the MacBook with Moonlight over Tailscale. Built for DCS, Falcon BMS and Ready or Not, and paid for with AWS Activate credits (expire 2027-07-31).

## Current machine

| | |
|---|---|
| Instance | `i-077325cb934a34acc` (`gaming-pc`), us-east-1a |
| Type | g6e.4xlarge: NVIDIA L40S 48GB, 16 vCPU (EPYC 7R13), 128GB RAM |
| Disk | 1TB gp3, 16000 IOPS, 2000MB/s (the instance caps EBS at 1000MB/s), `DeleteOnTermination=false` |
| OS | Windows Server 2022 |
| Network | Tailscale `gaming-pc` (100.106.1.28); Elastic IP 52.204.43.160 |
| AWS profile | `m5mbp` (`aws login --profile m5mbp --remote`) |

g7e (RTX PRO 6000 Blackwell) is the preferred type, but it was sold out in us-east-1 at build time. us-east-1a offers g7e, so upgrading is a stop → `modify-instance-attribute --instance-type g7e.4xlarge` → start. To avoid losing the slot to a capacity error, create a short On-Demand Capacity Reservation in us-east-1a first and cancel it once the instance is running.

## Daily use

`gpc` (in dotfiles, `~/.local/bin/gpc`):

```sh
gpc start         # boot, wait for Tailscale, open Moonlight
gpc stop          # shut down (the disk still bills)
gpc status
gpc ui            # Apollo web UI; copies the password to the clipboard
gpc rdp-password  # Windows Administrator password
```

The instance stops itself after 30 min with no streaming, downloading, disk writes or CPU load (`windows/idle.ps1`), with a CloudWatch backup alarm that stops it after 6h of near-zero NetworkOut. Long installs (for example DCS unpacking at about 50MB/s with no network traffic) count as busy.

## Moonlight settings

Stored in `~/Library/Preferences/com.moonlight-stream.Moonlight.plist`. Don't commit it, because it holds the pairing key.

| Setting | Value | plist key |
|---|---|---|
| Resolution | 3024×1890 (16:10, the MacBook screen minus the notch) | `width`, `height` |
| FPS | 120 | `fps` |
| Bitrate | 40 Mbps, no auto-adjust | `bitrate`, `autoadjustbitrate` |
| Codec | AV1 | `videocfg = 4` |
| Window | Borderless fullscreen | `windowmode = 1` |
| V-Sync, frame pacing | Off (each costs about a frame of latency) | `vsync`, `framepacing` |
| Mouse | Game (raw relative) mode, not "optimize for remote desktop"; ⌃⌥⇧M toggles mid-stream | `mouseacceleration = false` |

Quit Moonlight before editing the plist, or it overwrites the changes on exit.

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
- **Empty stream window.** The NVIDIA driver exposes its own display, so Apollo captured an empty secondary screen. Fixed with `dd_configuration_option = ensure_only_display`.
- **No audio device on EC2.** Steam no longer ships Steam Streaming Speakers in the client. Apollo installs them on the first stream; VB-Cable is installed so a playback device always exists.
- **Apollo web UI 403.** By default it only allows LAN origins; `origin_web_ui_allowed = wan` is safe because only the tailnet can reach it.
- **Public ports.** Only UDP 41641 (Tailscale direct) and the BMS installer's BitTorrent ports (TCP 36881-36999, UDP 6881-6999) are open. Moonlight, Apollo and RDP are reachable only over Tailscale.
- **BMS torrents stall at 0 peers** without those inbound ports, since the few seeders of add-ons like 16K terrain are also unreachable. A partial download (0-byte `.dds` in `Photoreal\16K`) crashes BMS in `ResourceManager::onCreateDevice` when a mission loads; rename the folder until it completes.
- **.NET 3.5** can't be added through Windows Features on Server; `setup.ps1` installs it with `Install-WindowsFeature`.
- **Reddit blocks AWS IPs.** Browse on the Mac instead.
- **Slow game installs.** Defender real-time scanning throttled DCS unpacking, so game folders and updaters are excluded. Downloads from Steam reach about 2.6 Gbps; the disk was the bottleneck at 600MB/s.

## Costs (on-demand, from credits)

- Instance: $3.74/hr (Windows included)
- Egress: $0.09/GB, roughly $5–7/hr total at 80–150 Mbps
- Disk + EIP: about $225/mo, even when stopped (1TB plus provisioned IOPS and throughput)

## Secrets (never in this repo)

- `~/.ssh/cloud-gaming.pem`: decrypts the Windows password
- Keychain `gaming-pc-windows`, `gaming-pc-apollo-ui`
- Moonlight plist (pairing key); Apollo `sunshine_state.json` on the instance
