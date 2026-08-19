# WANPilot for OpenWrt

![OpenWrt](https://img.shields.io/badge/OpenWrt-LuCI-blue?style=for-the-badge&logo=openwrt)
![Multi-WAN](https://img.shields.io/badge/Mode-Multi--WAN-orange?style=for-the-badge)
![Shell](https://img.shields.io/badge/Language-POSIX_Shell-green?style=for-the-badge&logo=gnu-bash)

[Русская версия](README_ru.md)

WANPilot is a lightweight OpenWrt uplink manager with a native LuCI dashboard, verified metric-based switching, and per-interface Google/Yandex connectivity and latency checks.

It works with the standard OpenWrt network stack: WANPilot does not replace routing, firewall, or interface management and does not require a separate multi-WAN framework.

---

## Features

- automatic uplink discovery from a configurable firewall zone;
- manual interface entries outside the discovery zone;
- active uplink detection from real default routes and effective metrics;
- clear equal-priority handling;
- verified uplink switching with automatic metric rollback on failure;
- independent Google and Yandex checks bound to each interface;
- `ONLINE` when at least one of Google or Yandex is reachable;
- stable RTT display with lightweight manual-probe animation;
- responsive cards on the standard LuCI Overview page;
- LuCI configuration and runtime status pages;
- CLI and `rpcd`/`ubus` API;
- support for both `apk` and `opkg` based OpenWrt releases.

---

## Quick Install

Run as `root` in the OpenWrt terminal:

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/F5GO/WANPilot/main/install.sh)"
```

If `wget` is unavailable, use the built-in OpenWrt downloader:

```sh
sh -c "$(uclient-fetch -O- https://raw.githubusercontent.com/F5GO/WANPilot/main/install.sh)"
```

The installer always downloads the current `main` branch from `F5GO/WANPilot`.

> [!CAUTION]
> Installation is intentionally clean: any existing WANPilot version and `/etc/config/wanpilot` are removed before the current version is installed with default settings. Standard OpenWrt packages and unrelated `pingcheck` sections are preserved.

After installation, open:

- `Status → Overview` for the dashboard widget;
- `Network → WANPilot → Configuration` for settings;
- `Network → WANPilot → Runtime Status` for detailed state.

---

## Requirements

| Component | Requirement |
|---|---|
| Router | OpenWrt with LuCI |
| Access | `root` shell access |
| Package manager | `apk` or `opkg` |
| Required components | `rpcd`, `luci-base`, `uhttpd` |
| Internet checks | `curl`; `pingcheck` is used for background integration |

Missing supported packages are installed automatically when available in the configured OpenWrt repositories.

---

## How Uplink Status Works

WANPilot separates interface state from internet reachability:

- `CONNECTED` means the interface is up and has a usable route;
- `ONLINE` means the interface has a default route and at least one latest Google/Yandex check succeeded;
- `OFFLINE` means both latest checks failed or the interface itself is unavailable;
- `CHECKING` means no completed connectivity result is available yet;
- `STOPPED` means the WANPilot service was stopped from the CLI.

Displayed latency is the average of three short ICMP samples through the selected interface. If ICMP is unavailable, WANPilot uses TCP connection time with DNS lookup removed. The old result remains visible only while the next check is running and is then replaced with the new RTT or `FAIL`.

`Check interval` is the delay between completed automatic cycles. `Check timeout` is the maximum duration of one target request.

---

## CLI

Common commands:

```sh
wanpilot status
wanpilot status --json
wanpilot list --json
wanpilot discover --json
wanpilot switch wan
wanpilot probe wan both
wanpilot probe wan google
wanpilot config get --json
```

Service control:

```sh
wanpilot stop
wanpilot start
wanpilot restart
```

- `stop` persistently disables WANPilot-managed checks and blocks new WANPilot probes;
- `start` enables them again using the saved configuration;
- `restart` enables WANPilot, clears stale probe state, resynchronizes its managed `pingcheck` sections, and restarts the integration;
- unrelated `pingcheck` configuration is not removed or disabled.

Run `wanpilot help` to display the complete command list.

---

## Configuration

WANPilot stores its settings in `/etc/config/wanpilot`. The main options are also available in LuCI:

- discovery firewall zone;
- preferred route metric;
- internet-check enable/disable;
- check interval and timeout;
- manual interfaces, display names, visibility, and order.

Interface metric history is stored only to safely restore values managed by WANPilot.

---

## Update

Run the installation command again. The installer retrieves the current `main` branch and performs a clean installation:

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/F5GO/WANPilot/main/install.sh)"
```

---

## Uninstall

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/F5GO/WANPilot/main/uninstall.sh)"
```

Alternative:

```sh
sh -c "$(uclient-fetch -O- https://raw.githubusercontent.com/F5GO/WANPilot/main/uninstall.sh)"
```

The uninstaller removes WANPilot files, configuration, LuCI/probe caches, and WANPilot-managed `pingcheck` sections. It restores managed interface metrics when possible. Shared OpenWrt packages are not removed.

---

## Contacts

The project is developed with support from the **F5GO.ONE** community.

- **YouTube:** [F5](https://youtube.com/@F5GO)
- **Website:** [F5GO.ONE](https://f5go.one)
- **Telegram:** [F5GO](https://t.me/f5gou)

---

> [!IMPORTANT]
> **MIT License.** This software is provided “as is”, without warranty. Use it at your own risk.
