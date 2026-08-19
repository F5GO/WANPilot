#!/bin/sh
# WANPilot GitHub uninstaller for complete removal from OpenWrt routers.

set -eu

die() {
        printf 'WANPilot uninstall error: %s\n' "$*" >&2
        exit 1
}

restart_service_if_present() {
        service="$1"

        if [ -x "/etc/init.d/${service}" ]; then
                "/etc/init.d/${service}" restart >/dev/null 2>&1 || true
        fi
}

restore_managed_metrics() {
        section=""
        iface=""
        baseline=""
        managed=""
        current=""
        changed=0
        state_file="/tmp/wanpilot-uninstall-state.$$"

        command -v uci >/dev/null 2>&1 || return 0
        [ -f /etc/config/wanpilot ] || return 0

        uci -q show wanpilot 2>/dev/null | sed -n 's/^wanpilot\.\(@state\[[0-9]\+\]\)=state$/\1/p' > "$state_file"

        while IFS= read -r section; do
                iface="$(uci -q get "wanpilot.${section}.interface" 2>/dev/null || true)"
                baseline="$(uci -q get "wanpilot.${section}.baseline_metric" 2>/dev/null || true)"
                managed="$(uci -q get "wanpilot.${section}.managed_metric" 2>/dev/null || true)"

                [ -n "$iface" ] || continue
                [ -n "$managed" ] || continue

                current="$(uci -q get "network.${iface}.metric" 2>/dev/null || true)"

                current="${current:-0}"
                baseline="${baseline:-0}"

                if [ "$current" = "$managed" ]; then
                        if [ "$baseline" = "0" ]; then
                                uci -q delete "network.${iface}.metric" 2>/dev/null || true
                        else
                                uci -q set "network.${iface}.metric=${baseline}"
                        fi
                        changed=1
                fi
        done < "$state_file"

        rm -f "$state_file"

        if [ "$changed" -eq 1 ]; then
                uci commit network
                ubus call network reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
        fi
}

remove_managed_pingcheck_config() {
        section=""
        managed=""
        changed=0
        sections_file="/tmp/wanpilot-uninstall-pingcheck.$$"

        command -v uci >/dev/null 2>&1 || return 0
        [ -f /etc/config/pingcheck ] || return 0

        uci -q show pingcheck 2>/dev/null | \
                sed -n \
                        -e 's/^pingcheck\.\(@default\[[0-9][0-9]*\]\)=.*/\1/p' \
                        -e 's/^pingcheck\.\(@interface\[[0-9][0-9]*\]\)=.*/\1/p' | \
                sed '1!G;h;$!d' > "$sections_file"

        while IFS= read -r section; do
                [ -n "$section" ] || continue
                managed="$(uci -q get "pingcheck.${section}.wanpilot_managed" 2>/dev/null || true)"
                [ "$managed" = "1" ] || continue
                uci -q delete "pingcheck.${section}" 2>/dev/null || true
                changed=1
        done < "$sections_file"

        rm -f "$sections_file"
        if [ "$changed" -eq 1 ]; then
                uci commit pingcheck
        fi
}

remove_wanpilot_files() {
        rm -f /etc/config/wanpilot
        rm -f /usr/bin/wanpilot
        rm -f /usr/libexec/rpcd/wanpilot
        rm -f /usr/libexec/wanpilot/core.sh
        rm -f /usr/share/rpcd/acl.d/wanpilot.json
        rm -f /usr/share/luci/menu.d/luci-app-wanpilot.json
        rm -f /www/luci-static/resources/view/wanpilot/config.js
        rm -f /www/luci-static/resources/view/wanpilot/status.js
        rm -f /www/luci-static/resources/view/status/include/30_wanpilot.js
        rmdir /usr/libexec/wanpilot 2>/dev/null || true
        rmdir /www/luci-static/resources/view/wanpilot 2>/dev/null || true
}

if [ "$(id -u)" -ne 0 ]; then
        die "Run this uninstaller as root."
fi

restore_managed_metrics
remove_managed_pingcheck_config
remove_wanpilot_files

rm -rf /tmp/wanpilot-online
rm -f /tmp/wanpilot-pingcheck.signature
rm -f /tmp/wanpilot-curl-*.tmp
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/*

restart_service_if_present pingcheck
restart_service_if_present rpcd
restart_service_if_present uhttpd

printf 'WANPilot was removed.\n'
