# VRChat Session Launcher (Linux)

One launcher for a Linux VR session with the Steam Frame and its Realtek Wi‑Fi dongle:

- tunes the dongle for low latency once the Frame is connected and SteamVR runs, and resets it when the link drops;
- opens the NVIDIA clock TUI in a root terminal;
- starts and supervises helper apps through Steam;
- cleans up on Ctrl+C.

## Quick start

```bash
bash vrchat-session-launcher.sh
```

Enter your sudo password once at startup.

### `holo-realtek-firmware-toggles` (MIT, Valve)

Valve's dongle script is **MIT licensed, © Valve Corporation**, and isn't included here. On first run the launcher downloads the newest `holo-realtek-firmware-toggles-*.src.tar.gz` from the [SteamOS Holo sources](https://steamdeck-packages.steamos.cloud/archlinux-mirror/sources/holo-3.10/) (needs `curl`), installs it next to the launcher, and writes a `holo-realtek-firmware-toggles.LICENSE` note.

Manual install:

```bash
curl -fLO https://steamdeck-packages.steamos.cloud/archlinux-mirror/sources/holo-3.10/holo-realtek-firmware-toggles-1.4-1.src.tar.gz
tar xzf holo-realtek-firmware-toggles-1.4-1.src.tar.gz
install -m 755 holo-realtek-firmware-toggles/holo-realtek-firmware-toggles .
rm -r holo-realtek-firmware-toggles holo-realtek-firmware-toggles-1.4-1.src.tar.gz
```

**Requirements:** `bash`, `curl` (first run), `sudo`, `iw`, `python3`, `pgrep`, `steam`, `nvidia-smi`, a terminal emulator (konsole, gnome-terminal, kitty, alacritty, xterm, …), and a Realtek `rtw89` dongle with debugfs.

## Files

| File | Purpose |
|---|---|
| `vrchat-session-launcher.sh` | Entry point: sudo setup, regulatory domain, Wi‑Fi watcher, then the watchdog. Resets the dongle on exit. |
| `session-watchdog.py` | Launches and supervises Steam apps and opens the clock TUI. |
| `clock-tui.sh` | Wrapper that records its PID and runs `nvidia-clock.sh`. |
| `nvidia-clock.sh` | NVIDIA clock TUI (see below). |
| `holo-realtek-firmware-toggles` | Valve's dongle tuning script (`set-low-latency-mode on`, `reset`, `list`), MIT, © Valve. Auto-downloaded on first run (see above). |
| `patch-steamvr_*` | SteamVR patch wrappers by Tomasz Kramkowski ([info](https://kramkow.ski/project/steamvr-patches.html)). See [SteamVR patcher](#steamvr-patcher). |

## SteamVR patcher

Pick the `patch-steamvr_*` matching your SteamVR build (the newest one usually), then:

1. Get its absolute path:
   ```bash
   realpath patch-steamvr_26655409_0_2_19_3
   ```
2. In Steam: **SteamVR → Properties → General → Launch Options**, set:
   ```
   /absolute/path/to/patch-steamvr_26655409_0_2_19_3 %command%
   ```
3. Launch SteamVR. A desktop notification shows whether patching happened. If it reports an unrecognized file hash, SteamVR updated and needs a newer wrapper.

## Session flow

1. **Launcher:** checks dependencies, keeps sudo alive, runs `iw reg set US` and resets the dongle. VRChat launch is currently off (`OPTIONAL=0`).
2. **Wi‑Fi watcher:** waits for a connection named *Frame* (3 checks, 2 s apart), then for SteamVR (`vrserver`) to run for 30 s, then enables low-latency mode. If the link drops, it resets the dongle and starts over.
3. **App watchdog:** opens the clock TUI, then starts enabled apps (Baballonia, VRCFaceTracking, VRCVideoCacher). Checks every 5 s, restarts crashed apps (max once per 60 s), retries apps that never appear after 180 s. If VRChat was launched and exits, monitoring stops 5 min later.
4. **Ctrl+C:** stops only the processes this session started, plus the clock TUI, and resets the dongle.

Settings at the top of `session-watchdog.py`:

| Setting | Meaning |
|---|---|
| `RUN_BABALLONIA`, `RUN_VRCFACETRACKING`, `RUN_VRCVIDEOCACHER` | `False` skips the app (all currently off). |
| `USE_STEAM_FOR_VRCVIDEOCACHER` | Launch through Steam, or run the `VRCVideoCacher` command. |
| `POLL`, `GRACE`, `COOLDOWN`, `WAIT_GAME` | Check interval, start window, restart cooldown, post-VRChat wait (seconds). |

## NVIDIA clock TUI

Clocks are calculated from what the GPU reports, so it works on any NVIDIA card. Limits apply only while `VRChat.exe` runs (or when forced with `f` / `--force`) and are reset afterwards.

- **Preset mode:** `1`–`9` pick a preset (core at 20–100 % of the card's max, memory always at max), `-`/`+` step, `c` core-only, `m` memory-only, `p` back to presets.
- **Manual mode** (`a` or Tab to toggle): `1`–`9` set the core level, `q`–`o` set the memory level, both lowest to highest.
- `f` force, `r`/`z` reset, `q`/`x` quit (`z`/`x` in manual mode).

Options: `--gpu INDEX`, `--poll SECONDS`, `--force` (or env `GPU`, `POLL_SECONDS`, `FORCE_DOWNCLOCK`).

## Limitations

- Steam apps are recognized by `SteamAppId`/`SteamGameId` in `/proc/<pid>/environ`; apps hiding these may be missed.
- Starting the same app manually during its 180 s start window can't be told apart from the launcher's own.
- No blanket `pkill` or `steam -shutdown`; programs ignoring SIGTERM must be closed by hand.
- Ctrl+C in the clock terminal stops only the TUI.

## License

[WTFPL](LICENSE) for my scripts. `patch-steamvr_*` are CC0 by Tomasz Kramkowski <tomasz@kramkow.ski>; `holo-realtek-firmware-toggles` is MIT, © Valve Corporation.
