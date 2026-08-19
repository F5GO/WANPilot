#!/bin/sh
# WANPilot clean GitHub installer for direct installation on OpenWrt routers.

set -eu

: "${WANPILOT_GITHUB_OWNER:=F5GO}"
: "${WANPILOT_GITHUB_REPO:=WANPilot}"
: "${WANPILOT_GITHUB_REF:=main}"

REPO_ARCHIVE_URL="https://codeload.github.com/${WANPILOT_GITHUB_OWNER}/${WANPILOT_GITHUB_REPO}/tar.gz/refs/heads/${WANPILOT_GITHUB_REF}"
TMP_DIR="$(mktemp -d /tmp/wanpilot-install.XXXXXX)"

cleanup() {
	rm -rf "$TMP_DIR"
}

die() {
	printf 'WANPilot installer error: %s\n' "$*" >&2
	exit 1
}

fetch_to_file() {
        url="$1"
        destination="$2"

	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -O "$destination" "$url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fL "$url" -o "$destination"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$destination" "$url"
	else
		die "No supported downloader found. Install wget, curl or uclient-fetch first."
	fi
}

ensure_parent_dir() {
        target="$1"
        parent=""

	parent="$(dirname "$target")"
	mkdir -p "$parent"
}

install_file() {
        source="$1"
        target="$2"
        mode="$3"

	ensure_parent_dir "$target"
	cp "$source" "$target"
	chmod "$mode" "$target"
}

install_config_if_missing() {
        source="$1"
        target="$2"
        mode="$3"

	ensure_parent_dir "$target"
	if [ ! -e "$target" ]; then
		cp "$source" "$target"
		chmod "$mode" "$target"
	fi
}

restart_service_if_present() {
        service="$1"

	if [ -x "/etc/init.d/${service}" ]; then
		"/etc/init.d/${service}" restart >/dev/null 2>&1 || true
	fi
}

pkg_manager() {
	if command -v apk >/dev/null 2>&1; then
		printf 'apk\n'
	elif command -v opkg >/dev/null 2>&1; then
		printf 'opkg\n'
	else
		printf 'none\n'
	fi
}

pkg_installed() {
        manager="$1"
        package_name="$2"

	case "$manager" in
		apk)
			apk info -e "$package_name" >/dev/null 2>&1
			;;
		opkg)
			opkg status "$package_name" >/dev/null 2>&1
			;;
		*)
			return 1
			;;
	esac
}

pkg_update() {
        manager="$1"

	case "$manager" in
		apk)
			apk update
			;;
		opkg)
			opkg update
			;;
		*)
			die "No supported package manager found."
			;;
	esac
}

pkg_install() {
        manager="$1"
	shift

	case "$manager" in
		apk)
			apk add "$@"
			;;
		opkg)
			opkg install "$@"
			;;
		*)
			die "No supported package manager found."
			;;
	esac
}

ensure_optional_package() {
	manager="$1"
	package_name="$2"

	if pkg_installed "$manager" "$package_name"; then
		return 0
	fi

	printf 'Attempting to install optional package: %s\n' "$package_name"
	pkg_update "$manager"
	if pkg_install "$manager" "$package_name"; then
		return 0
	fi

	printf 'Optional package %s is unavailable. WANPilot will keep working, but per-uplink internet checks will stay disabled.\n' "$package_name" >&2
}

ensure_packages() {
        manager="$1"
	shift
        package_name=""
        missing_file="${TMP_DIR}/missing-packages.txt"

        : > "$missing_file"
        for package_name do
		if ! pkg_installed "$manager" "$package_name"; then
                        printf '%s\n' "$package_name" >> "$missing_file"
		fi
	done

        if [ -s "$missing_file" ]; then
                printf 'Installing missing packages: %s\n' "$(tr '\n' ' ' < "$missing_file" | sed 's/ $//')"
		pkg_update "$manager"
                set --
                while IFS= read -r package_name; do
                        set -- "$@" "$package_name"
                done < "$missing_file"
                pkg_install "$manager" "$@"
	fi
}

if [ "$(id -u)" -ne 0 ]; then
	die "Run this installer as root."
fi

trap cleanup EXIT INT TERM

PKG_MANAGER="$(pkg_manager)"
if [ "$PKG_MANAGER" = "none" ]; then
	die "No supported package manager found. Expected apk or opkg."
fi

ensure_packages "$PKG_MANAGER" \
	rpcd \
	luci-base \
	luci-mod-network \
	luci-mod-status \
	uhttpd \
	uhttpd-mod-ubus

ensure_optional_package "$PKG_MANAGER" pingcheck
ensure_optional_package "$PKG_MANAGER" curl

ARCHIVE_FILE="${TMP_DIR}/wanpilot.tar.gz"
printf 'Downloading WANPilot from %s\n' "$REPO_ARCHIVE_URL"
fetch_to_file "$REPO_ARCHIVE_URL" "$ARCHIVE_FILE"

tar -xzf "$ARCHIVE_FILE" -C "$TMP_DIR"
SOURCE_ROOT="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$SOURCE_ROOT" ] || die "Unable to locate extracted repository contents."
[ -f "${SOURCE_ROOT}/uninstall.sh" ] || die "Downloaded repository is missing uninstall.sh."

printf 'Removing any previously installed WANPilot version\n'
sh "${SOURCE_ROOT}/uninstall.sh"

printf 'Installing WANPilot core files\n'
install_config_if_missing "${SOURCE_ROOT}/wanpilot/files/etc/config/wanpilot" "/etc/config/wanpilot" 0644
install_file "${SOURCE_ROOT}/wanpilot/files/usr/bin/wanpilot" "/usr/bin/wanpilot" 0755
install_file "${SOURCE_ROOT}/wanpilot/files/usr/libexec/wanpilot/core.sh" "/usr/libexec/wanpilot/core.sh" 0755
install_file "${SOURCE_ROOT}/wanpilot/files/usr/libexec/rpcd/wanpilot" "/usr/libexec/rpcd/wanpilot" 0755
install_file "${SOURCE_ROOT}/wanpilot/files/usr/share/rpcd/acl.d/wanpilot.json" "/usr/share/rpcd/acl.d/wanpilot.json" 0644

printf 'Installing LuCI integration files\n'
install_file "${SOURCE_ROOT}/luci-app-wanpilot/root/usr/share/luci/menu.d/luci-app-wanpilot.json" "/usr/share/luci/menu.d/luci-app-wanpilot.json" 0644
install_file "${SOURCE_ROOT}/luci-app-wanpilot/htdocs/luci-static/resources/view/wanpilot/config.js" "/www/luci-static/resources/view/wanpilot/config.js" 0644
install_file "${SOURCE_ROOT}/luci-app-wanpilot/htdocs/luci-static/resources/view/wanpilot/status.js" "/www/luci-static/resources/view/wanpilot/status.js" 0644
install_file "${SOURCE_ROOT}/luci-app-wanpilot/htdocs/luci-static/resources/view/status/include/30_wanpilot.js" "/www/luci-static/resources/view/status/include/30_wanpilot.js" 0644

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/*
rm -f /tmp/luci-* 2>/dev/null || true

restart_service_if_present rpcd
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd reload 2>/dev/null || true
fi
restart_service_if_present uhttpd

if ! command -v wanpilot >/dev/null 2>&1; then
	die "wanpilot command was not installed correctly."
fi

wanpilot sync >/dev/null 2>&1 || true

printf '\nInstallation finished.\n'
printf 'Quick checks:\n'
printf '  wanpilot status --json\n'
printf '  ubus list | grep wanpilot\n'
printf '  Open LuCI: Network -> WANPilot\n'
