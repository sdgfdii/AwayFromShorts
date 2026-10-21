# AwayFromShorts

> A self-control tool for short-video addiction. Blocks at the OS level, not with a timer you can dismiss.

[![Release](https://img.shields.io/github/v/release/sdgfdii/AwayFromShorts?label=release)](https://github.com/sdgfdii/AwayFromShorts/releases/latest)
[![License](https://img.shields.io/github/license/sdgfdii/AwayFromShorts)](LICENSE)

[中文说明](README.md) · **Android 端在另一个仓库: [AwayFromShorts-Phone](https://github.com/sdgfdii/AwayFromShorts-Phone)**

---

This repository is the **Windows** side: hosts-level site blocking, process killing, browser-window
closing, and a local web panel. Pure PowerShell, zero dependencies.

The **Android** side (Device Owner freeze / accessibility blocker) lives in a separate repo:
**[sdgfdii/AwayFromShorts-Phone](https://github.com/sdgfdii/AwayFromShorts-Phone)**.

---

## Windows

```powershell
irm https://raw.githubusercontent.com/sdgfdii/AwayFromShorts/main/install.ps1 | iex
```

Or grab `AwayFromShorts-Setup-2.0.0.exe` from
[Releases](https://github.com/sdgfdii/AwayFromShorts/releases/latest), double-click, click "Yes" on the
UAC prompt. It unpacks to `%LOCALAPPDATA%\AwayFromShorts`, backs up hosts, registers a scheduled task
(every minute, highest privileges, runs without login), enables auto-start, and opens the panel at
**http://127.0.0.1:8737**.

The panel UI is Chinese-only.

### What it does

| | |
|---|---|
| **Weekly schedule** | Pick weekdays and one or more time windows (cross-midnight supported) |
| **Site blocking** | Writes `0.0.0.0 domain` into hosts — the browser simply can't resolve it |
| **Process blocking** | `Stop-Process` on matching names, re-checked every minute so restarting doesn't help |
| **Browser window blocking** | Gracefully closes browser windows whose title matches (e.g. an "Entertainment" workspace), other windows untouched |
| **Allow-list** | Domains and processes that are never blocked |
| **Temp override** | "Block 30 min" / "Unblock 30 min", auto-reverts on expiry |
| **Stats** | Every override is logged (count + duration), plus ActivityWatch-style time-per-app tracking |
| **Gist sync** | Push/pull the config to a private GitHub Gist; token is DPAPI-encrypted locally |

### Force mode

When enabled it only applies **inside** the scheduled blocking window:

- You cannot disable blocking or temporarily unblock — the API returns 403 and the UI hides the button
- It **does not auto-renew**: it expires at 24:00 the same day and the engine releases it
- Outside the window (or on a weekday you didn't select) it does nothing — a switch that's "on" is not
  necessarily "active right now"

**Uninstall guard**: while force mode is actually active you cannot uninstall — the panel button greys out
and running `uninstall.bat` directly is refused by the same script, without touching any file
(scheduled task, hosts, program directory all stay intact). The reverse is also explicit: a switch that's
on but outside its window does **not** block uninstall.

There's one more anti-tamper check: if `config.json` says force mode is off but a `force-state.json`
is left behind (the trace of hand-editing the config to sneak out), uninstall is still blocked.

### How it works

```
config.json ──(scheduled task, every minute, SYSTEM-level)──▶ engine: awayfromshorts.ps1
     ▲                                                          │ schedule hit?
     │ save rules                                        ┌──────┴──────┐
web panel (webui.ps1 @127.0.0.1:8737)                   │ yes: hosts  │  no: clear hosts
                                                        │  + kill     │
                                                        └─────────────┘
```

Config lives at `%LOCALAPPDATA%\AwayFromShorts\src\config.json` — plain JSON, safe to edit by hand
(hit "Apply now" in the panel afterwards).

### Uninstall

Panel → "About / Uninstall", or run `%LOCALAPPDATA%\AwayFromShorts\uninstall.bat` as administrator.
It removes the scheduled task, strips only the lines this program wrote from hosts, and deletes the
program directory.

---

## License

MIT. Do whatever you want with it.
