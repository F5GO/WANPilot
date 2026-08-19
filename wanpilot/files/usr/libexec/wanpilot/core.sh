#!/bin/sh
# WANPilot core library for discovery, status collection, switching and UCI metadata.
# shellcheck disable=SC1091,SC3043

. /usr/share/libubox/jshn.sh

WP_CONFIG="wanpilot"
WP_NETWORK_CONFIG="network"
WP_FIREWALL_CONFIG="firewall"
WP_PINGCHECK_CONFIG="pingcheck"
WP_DEFAULT_ZONE="wan"
WP_DEFAULT_PREFERRED_METRIC="10"
WP_DEFAULT_ONLINE_CHECK_ENABLED="1"
WP_DEFAULT_ONLINE_CHECK_URL="https://www.gstatic.com/generate_204"
WP_DEFAULT_ONLINE_CHECK_INTERVAL="10"
WP_DEFAULT_ONLINE_CHECK_TIMEOUT="4"
WP_PINGCHECK_SIGNATURE_FILE="/tmp/wanpilot-pingcheck.signature"
WP_ONLINE_PROBE_CACHE_DIR="/tmp/wanpilot-online"
WP_ONLINE_PROBE_TARGET_GOOGLE="https://www.gstatic.com/generate_204"
WP_ONLINE_PROBE_TARGET_YANDEX="https://ya.ru/"

wp_list_sections() {
	local config_name="$1"
	local section_type="$2"

	uci -q show "$config_name" 2>/dev/null | \
		sed -n "s/^${config_name}\.\(@${section_type}\[[0-9]\+\]\)=${section_type}$/\1/p"
}

wp_find_managed_pingcheck_section() {
	local section_type="$1"
	local section managed

	for section in $(wp_list_sections "$WP_PINGCHECK_CONFIG" "$section_type"); do
		managed="$(uci -q get "${WP_PINGCHECK_CONFIG}.${section}.wanpilot_managed" 2>/dev/null || true)"
		if [ "$managed" = "1" ]; then
			printf '%s\n' "$section"
			return 0
		fi
	done
	return 1
}

wp_get_main_option() {
	local option_name="$1"
	local default_value="$2"
	local value

	value="$(uci -q get "${WP_CONFIG}.main.${option_name}" 2>/dev/null)"
	if [ -n "$value" ]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$default_value"
	fi
}

wp_get_discovery_zone() {
	wp_get_main_option "discovery_zone" "$WP_DEFAULT_ZONE"
}

wp_get_preferred_metric() {
	wp_get_main_option "preferred_metric" "$WP_DEFAULT_PREFERRED_METRIC"
}

wp_get_online_check_url() {
        wp_get_main_option "online_check_url" "$WP_DEFAULT_ONLINE_CHECK_URL"
}

wp_get_online_check_timeout() {
        local value

        value="$(wp_get_main_option "online_check_timeout" "$WP_DEFAULT_ONLINE_CHECK_TIMEOUT")"
        case "$value" in
                ''|*[!0-9]*)
                        printf '%s\n' "$WP_DEFAULT_ONLINE_CHECK_TIMEOUT"
                        ;;
                *)
                        if [ "$value" -gt 0 ] 2>/dev/null; then
                                printf '%s\n' "$value"
                        else
                                printf '%s\n' "$WP_DEFAULT_ONLINE_CHECK_TIMEOUT"
                        fi
                        ;;
        esac
}

wp_get_online_check_interval() {
        local value

	value="$(uci -q get "${WP_CONFIG}.main.online_check_interval" 2>/dev/null)"
	[ -n "$value" ] || value="$(uci -q get "${WP_CONFIG}.main.online_check_cache_ttl" 2>/dev/null)"
	[ -n "$value" ] || value="$WP_DEFAULT_ONLINE_CHECK_INTERVAL"
        case "$value" in
                ''|*[!0-9]*)
			printf '%s\n' "$WP_DEFAULT_ONLINE_CHECK_INTERVAL"
                        ;;
                *)
			if [ "$value" -gt 0 ] 2>/dev/null; then
                                printf '%s\n' "$value"
                        else
				printf '%s\n' "$WP_DEFAULT_ONLINE_CHECK_INTERVAL"
                        fi
                        ;;
        esac
}

wp_is_enabled_value() {
        case "$1" in
                1|true|yes|on|enabled)
                        return 0
                        ;;
                *)
                        return 1
                        ;;
        esac
}

wp_online_check_enabled() {
        wp_is_enabled_value "$(wp_get_main_option "online_check_enabled" "$WP_DEFAULT_ONLINE_CHECK_ENABLED")"
}

wp_online_check_enabled_flag() {
        if wp_online_check_enabled; then
                printf '1\n'
        else
                printf '0\n'
        fi
}

wp_service_running_flag() {
	if wp_is_enabled_value "$(wp_get_main_option "service_enabled" "1")"; then
		printf '1\n'
	else
		printf '0\n'
	fi
}

wp_effective_online_check_enabled_flag() {
	if [ "$(wp_service_running_flag)" = "1" ] && [ "$(wp_online_check_enabled_flag)" = "1" ]; then
		printf '1\n'
	else
		printf '0\n'
	fi
}

wp_pingcheck_available() {
	[ -x /etc/init.d/pingcheck ] || return 1
	ubus list pingcheck >/dev/null 2>&1
}

wp_online_check_supported_flag() {
	if command -v curl >/dev/null 2>&1; then
                printf '1\n'
        else
                printf '0\n'
        fi
}

wp_first_ipv4_from_list() {
        local first

        first="${1%% *}"
        printf '%s\n' "${first%%/*}"
}

wp_mark_online_backend_dirty() {
	rm -f "$WP_PINGCHECK_SIGNATURE_FILE"
}

wp_online_check_url_authority() {
	local url="$1"
	local authority

	authority="${url#*://}"
	authority="${authority%%/*}"
	authority="${authority%%\?*}"
	printf '%s\n' "$authority"
}

wp_online_check_url_host() {
	local authority

	authority="$(wp_online_check_url_authority "$1")"

        case "$authority" in
                *:*)
                        printf '%s\n' "${authority%%:*}"
                        ;;
                *)
                        printf '%s\n' "$authority"
                        ;;
        esac
}

wp_online_check_url_port() {
        local url="$1"
	local authority scheme

	authority="$(wp_online_check_url_authority "$url")"
	scheme="${url%%://*}"
	[ "$scheme" != "$url" ] || scheme=""

        case "$authority" in
                *:*)
                        printf '%s\n' "${authority##*:}"
                        ;;
		*)
			case "$scheme" in
				https)
					printf '443\n'
					;;
				*)
					printf '80\n'
					;;
			esac
			;;
        esac
}

wp_pingcheck_signature() {
	local candidates_file iface origin manual zone display_name hidden order warning
	local signature_file

	candidates_file="$(mktemp)" || return 1
	signature_file="$(mktemp)" || {
		rm -f "$candidates_file"
		return 1
	}

	wp_collect_candidates > "$candidates_file"

	{
		printf 'enabled=%s\n' "$(wp_effective_online_check_enabled_flag)"
		printf 'url=%s\n' "$(wp_get_online_check_url)"
		printf 'host=%s\n' "$(wp_online_check_url_host "$(wp_get_online_check_url)")"
		printf 'port=%s\n' "$(wp_online_check_url_port "$(wp_get_online_check_url)")"
		printf 'interval=%s\n' "$(wp_get_online_check_interval)"
		printf 'timeout=%s\n' "$(wp_get_online_check_timeout)"

		while IFS='	' read -r iface origin manual zone display_name hidden order warning; do
			[ -n "$iface" ] || continue
			wp_network_iface_exists "$iface" || continue
			printf 'iface=%s\n' "$iface"
		done < "$candidates_file"
	} > "$signature_file"

	cksum "$signature_file" | awk '{ print $1 ":" $2 }'
	rm -f "$candidates_file" "$signature_file"
}

wp_pingcheck_actual_state_matches() {
	local expected_host expected_port expected_enabled expected_ifaces
	local default_section actual_host actual_protocol actual_port actual_enabled managed
	local section actual_name actual_managed actual_disabled
	local candidates_file iface origin manual zone display_name hidden order warning
	local seen=0 missing=0

	[ -x /etc/init.d/pingcheck ] || return 1

	expected_host="$(wp_online_check_url_host "$(wp_get_online_check_url)")"
	expected_port="$(wp_online_check_url_port "$(wp_get_online_check_url)")"
	expected_enabled="$(wp_effective_online_check_enabled_flag)"

	default_section="$(wp_find_managed_pingcheck_section "default" 2>/dev/null || true)"
	if [ -z "$default_section" ]; then
		return 1
	fi

	actual_host="$(uci -q get "${WP_PINGCHECK_CONFIG}.${default_section}.host" 2>/dev/null || true)"
	actual_protocol="$(uci -q get "${WP_PINGCHECK_CONFIG}.${default_section}.protocol" 2>/dev/null || true)"
	actual_port="$(uci -q get "${WP_PINGCHECK_CONFIG}.${default_section}.tcp_port" 2>/dev/null || true)"
	managed="$(uci -q get "${WP_PINGCHECK_CONFIG}.${default_section}.wanpilot_managed" 2>/dev/null || true)"
	actual_disabled="$(uci -q get "${WP_PINGCHECK_CONFIG}.${default_section}.disabled" 2>/dev/null || true)"
	case "$actual_disabled" in 1|true|yes|on|enabled) actual_enabled=0 ;; *) actual_enabled=1 ;; esac

	[ "$managed" = "1" ] || return 1
	[ "$actual_host" = "$expected_host" ] || return 1
	[ "$actual_protocol" = "tcp" ] || return 1
	[ "$actual_port" = "$expected_port" ] || return 1
	[ "$actual_enabled" = "$expected_enabled" ] || return 1

	candidates_file="$(mktemp)" || return 1
	wp_collect_candidates > "$candidates_file"

	expected_ifaces=""
	while IFS='	' read -r iface origin manual zone display_name hidden order warning; do
		[ -n "$iface" ] || continue
		wp_network_iface_exists "$iface" || continue
		expected_ifaces="${expected_ifaces}${expected_ifaces:+ }${iface}"
	done < "$candidates_file"
	rm -f "$candidates_file"

	for section in $(wp_list_sections "$WP_PINGCHECK_CONFIG" "interface"); do
		actual_managed="$(uci -q get "${WP_PINGCHECK_CONFIG}.${section}.wanpilot_managed" 2>/dev/null || true)"
		[ "$actual_managed" = "1" ] || continue
		actual_name="$(uci -q get "${WP_PINGCHECK_CONFIG}.${section}.name" 2>/dev/null || true)"
		[ -n "$actual_name" ] || continue
		seen=$((seen + 1))
		case " $expected_ifaces " in
			*" $actual_name "*)
				;;
			*)
				missing=$((missing + 1))
				;;
		esac
	done

	local expected_count=0
	local _i
	for _i in $expected_ifaces; do expected_count=$((expected_count + 1)); done

	[ "$missing" -eq 0 ] || return 1
	[ "$seen" -eq "$expected_count" ] || return 1

	return 0
}

wp_online_probe_cache_init() {
	mkdir -p "$WP_ONLINE_PROBE_CACHE_DIR" 2>/dev/null || true
}

wp_online_probe_cache_get() {
	local key="$1"
	local ttl="$2"
	local cache_file="${WP_ONLINE_PROBE_CACHE_DIR}/${key}"
	local now ts diff value

	[ -f "$cache_file" ] || return 1
	now="$(date +%s 2>/dev/null || printf '0')"
	[ "$now" -gt 0 ] 2>/dev/null || return 1

	ts="$(head -n1 "$cache_file" 2>/dev/null || printf '0')"
	diff=$((now - ts))
	[ "$diff" -ge 0 ] 2>/dev/null || return 1
	[ "$diff" -lt "$ttl" ] 2>/dev/null || return 1

	value="$(tail -n1 "$cache_file" 2>/dev/null || true)"
	[ -n "$value" ] || return 1
	printf '%s\n' "$value"
	return 0
}

wp_online_probe_cache_set() {
	local key="$1"
	local value="$2"
	local cache_file="${WP_ONLINE_PROBE_CACHE_DIR}/${key}"
	local now

	wp_online_probe_cache_init
	now="$(date +%s 2>/dev/null || printf '0')"
	{
		printf '%s\n' "$now"
		printf '%s\n' "$value"
	} > "$cache_file" 2>/dev/null || true
}

wp_online_probe_record_result() {
	local iface="$1"
	local target="$2"
	local ok="$3"
	local target_key google_key yandex_key both_key
	local google_state yandex_state

	target_key="$(printf '%s__%s' "$iface" "$target" | tr -c 'A-Za-z0-9_-' '_')"
	if [ "$ok" -eq 1 ] 2>/dev/null; then
		wp_online_probe_cache_set "$target_key" "online"
	else
		wp_online_probe_cache_set "$target_key" "offline"
	fi

	google_key="$(printf '%s__google' "$iface" | tr -c 'A-Za-z0-9_-' '_')"
	yandex_key="$(printf '%s__yandex' "$iface" | tr -c 'A-Za-z0-9_-' '_')"
	both_key="$(printf '%s__both' "$iface" | tr -c 'A-Za-z0-9_-' '_')"
	google_state="$(wp_online_probe_cache_get "$google_key" 999999 2>/dev/null || true)"
	yandex_state="$(wp_online_probe_cache_get "$yandex_key" 999999 2>/dev/null || true)"

	if [ "$google_state" = "online" ] || [ "$yandex_state" = "online" ]; then
		wp_online_probe_cache_set "$both_key" "online"
	elif [ "$google_state" = "offline" ] && [ "$yandex_state" = "offline" ]; then
		wp_online_probe_cache_set "$both_key" "offline"
	else
		rm -f "${WP_ONLINE_PROBE_CACHE_DIR}/${both_key}" 2>/dev/null || true
	fi
}

wp_ping_probe_target() {
	local bind_iface="$1"
	local target_host="$2"
	local timeout="${3:-4}"
	local ping_args raw average

	command -v ping >/dev/null 2>&1 || return 1
	[ -n "$target_host" ] || return 1

	ping_args="-c 3 -i 0.2 -W ${timeout}"
	if [ -n "$bind_iface" ]; then
		ping_args="${ping_args} -I ${bind_iface}"
	fi
	# shellcheck disable=SC2086
	raw="$(ping $ping_args "$target_host" 2>/dev/null || true)"
	average="$(printf '%s\n' "$raw" | sed -n 's/.*= [^/]*\/\([^/]*\)\/.*/\1/p' | sed -n '1p')"

	if [ -z "$average" ]; then
		ping_args="-c 1 -W ${timeout}"
		if [ -n "$bind_iface" ]; then
			ping_args="${ping_args} -I ${bind_iface}"
		fi
		# shellcheck disable=SC2086
		raw="$(ping $ping_args "$target_host" 2>/dev/null || true)"
		average="$(printf '%s\n' "$raw" | sed -n 's/.*time[=<]\([0-9.][0-9.]*\)[[:space:]]*ms.*/\1/p' | sed -n '1p')"
	fi

	[ -n "$average" ] || return 1
	awk -v t="$average" 'BEGIN { if (t < 0) exit 1; if (t > 0 && t < 1) t = 1; printf "%.0f\n", t }' 2>/dev/null
}

wp_curl_probe_target() {
	local bind_iface="$1"
	local target_url="$2"
	local timeout="${3:-4}"
	local connect_timeout
	local raw
	local http_code
	local time_namelookup
	local time_connect
	local ping_rtt
	local wofile

	command -v curl >/dev/null 2>&1 || return 1

	case "$timeout" in
		''|*[!0-9]*) timeout=4 ;;
	esac
	connect_timeout=$((timeout / 2))
	[ "$connect_timeout" -gt 0 ] 2>/dev/null || connect_timeout=1

	wp_online_probe_cache_init
	wofile="$(mktemp "${WP_ONLINE_PROBE_CACHE_DIR}/curl.XXXXXX" 2>/dev/null || printf '/tmp/wanpilot-curl-$$.tmp')"

	curl_args="--silent"
	curl_args="${curl_args} --connect-timeout ${connect_timeout}"
	curl_args="${curl_args} --max-time ${timeout}"
	curl_args="${curl_args} --output /dev/null"
	curl_args="${curl_args} --write-out CODE;%{http_code};DNS;%{time_namelookup};CONNECT;%{time_connect};"
	if [ -n "$bind_iface" ]; then
		curl_args="${curl_args} --interface ${bind_iface}"
	fi

	# shellcheck disable=SC2086
	( curl $curl_args "$target_url" ) > "$wofile" 2>/dev/null

	raw=""
	if [ -r "$wofile" ]; then
		raw="$(cat "$wofile" 2>/dev/null || true)"
	fi
	rm -f "$wofile" 2>/dev/null || true

	http_code=""
	time_namelookup=""
	time_connect=""
	if [ -n "$raw" ]; then
		# TCP latency is connect time minus DNS lookup time. Unlike time_total,
		# this excludes TLS negotiation and remote HTTP server processing.
		http_code="$(printf '%s\n' "$raw" | sed -n 's/.*CODE;\([0-9]*\);.*/\1/p')"
		time_namelookup="$(printf '%s\n' "$raw" | sed -n 's/.*DNS;\([0-9.]*\);.*/\1/p')"
		time_connect="$(printf '%s\n' "$raw" | sed -n 's/.*CONNECT;\([0-9.]*\);.*/\1/p')"
	fi

	if [ -z "$http_code" ] || [ "$http_code" = "0" ]; then
		return 1
	fi

	local rtt_ms=0
	if [ -n "$time_connect" ] && [ "$time_connect" != "0" ]; then
		rtt_ms="$(awk -v c="$time_connect" -v d="${time_namelookup:-0}" 'BEGIN { t = (c - d) * 1000; if (t < 0) t = 0; if (t > 0 && t < 1) t = 1; printf "%.0f", t }' 2>/dev/null || printf '0')"
		case "$rtt_ms" in
			''|*[!0-9]*) rtt_ms=0 ;;
		esac
	fi
	case "$http_code" in
		200|201|202|203|204|205|206|301|302|304|307|308)
			ping_rtt="$(wp_ping_probe_target "$bind_iface" "$(wp_online_check_url_host "$target_url")" "$timeout" 2>/dev/null || true)"
			case "$ping_rtt" in
				''|*[!0-9]*) ;;
				*) rtt_ms="$ping_rtt" ;;
			esac
			printf '%s %s\n' "$http_code" "$rtt_ms"
			return 0
			;;
		*)
			printf 'ERR:%s %s\n' "$http_code" "$rtt_ms"
			return 1
			;;
	esac
}

wp_sync_pingcheck_config() {
	local enabled check_url host port interval timeout signature previous_signature
	local default_section section managed iface origin manual zone display_name hidden order warning
        local candidates_file

	[ -x /etc/init.d/pingcheck ] || return 1

	check_url="$(wp_get_online_check_url)"
	host="$(wp_online_check_url_host "$check_url")"
	port="$(wp_online_check_url_port "$check_url")"
	[ -n "$host" ] || return 1
	[ -n "$port" ] || return 1

	enabled="$(wp_effective_online_check_enabled_flag)"
        interval="$(wp_get_online_check_interval)"
        timeout="$(wp_get_online_check_timeout)"
	signature="$(wp_pingcheck_signature)" || return 1
	previous_signature="$(cat "$WP_PINGCHECK_SIGNATURE_FILE" 2>/dev/null || true)"
        local actual_matches="0"
        if wp_pingcheck_actual_state_matches 2>/dev/null; then
                actual_matches="1"
        else
                rm -f "$WP_PINGCHECK_SIGNATURE_FILE"
                previous_signature=""
        fi
	if [ "$actual_matches" = "1" ] && [ "$signature" = "$previous_signature" ] && wp_pingcheck_available; then
		return 0
	fi

	default_section="$(wp_find_managed_pingcheck_section "default" 2>/dev/null || true)"
	[ -n "$default_section" ] || default_section="$(uci add "$WP_PINGCHECK_CONFIG" default)"

	uci -q set "${WP_PINGCHECK_CONFIG}.${default_section}.host=${host}"
	uci -q set "${WP_PINGCHECK_CONFIG}.${default_section}.interval=${interval}"
	uci -q set "${WP_PINGCHECK_CONFIG}.${default_section}.timeout=${timeout}"
	uci -q set "${WP_PINGCHECK_CONFIG}.${default_section}.protocol=tcp"
	uci -q set "${WP_PINGCHECK_CONFIG}.${default_section}.tcp_port=${port}"
	uci -q set "${WP_PINGCHECK_CONFIG}.${default_section}.wanpilot_managed=1"
	if [ "$enabled" = "1" ]; then
		uci -q delete "${WP_PINGCHECK_CONFIG}.${default_section}.disabled" 2>/dev/null || true
	else
		uci -q set "${WP_PINGCHECK_CONFIG}.${default_section}.disabled=1"
	fi

	for section in $(wp_list_sections "$WP_PINGCHECK_CONFIG" "interface"); do
		managed="$(uci -q get "${WP_PINGCHECK_CONFIG}.${section}.wanpilot_managed" 2>/dev/null)"
		[ "$managed" = "1" ] || continue
		uci -q delete "${WP_PINGCHECK_CONFIG}.${section}"
	done

	candidates_file="$(mktemp)" || return 1
	wp_collect_candidates > "$candidates_file"

	while IFS='	' read -r iface origin manual zone display_name hidden order warning; do
		[ -n "$iface" ] || continue
		wp_network_iface_exists "$iface" || continue


		section="$(uci add "$WP_PINGCHECK_CONFIG" interface)"
		uci -q set "${WP_PINGCHECK_CONFIG}.${section}.name=${iface}"
		uci -q set "${WP_PINGCHECK_CONFIG}.${section}.wanpilot_managed=1"
		if [ "$enabled" = "1" ]; then
			uci -q delete "${WP_PINGCHECK_CONFIG}.${section}.disabled" 2>/dev/null || true
		else
			uci -q set "${WP_PINGCHECK_CONFIG}.${section}.disabled=1"
		fi
	done < "$candidates_file"

	rm -f "$candidates_file"

	uci commit "$WP_PINGCHECK_CONFIG"
	/etc/init.d/pingcheck enable >/dev/null 2>&1 || true
	/etc/init.d/pingcheck restart >/dev/null 2>&1 || true
	printf '%s\n' "$signature" > "$WP_PINGCHECK_SIGNATURE_FILE"
	wp_pingcheck_available
}

wp_service_set_running() {
	local enabled="$1"

	uci -q set "${WP_CONFIG}.main.service_enabled=${enabled}" || return 1
	uci commit "$WP_CONFIG" || return 1
	rm -f "$WP_PINGCHECK_SIGNATURE_FILE"
	rm -rf /tmp/wanpilot-online
	wp_sync_pingcheck_config >/dev/null 2>&1 || true
}

wp_service_stop() {
	wp_service_set_running 0
}

wp_service_start() {
	wp_service_set_running 1
}

wp_service_restart() {
	wp_service_set_running 1
}

wp_resolve_online_state() {
        local iface="$1"
        local cache_key
        local cached_state

	WP_STATUS_ONLINE=0
	WP_STATUS_ONLINE_STATE="offline"

	if [ "$(wp_service_running_flag)" != "1" ]; then
		WP_STATUS_ONLINE_STATE="stopped"
		return 0
	fi

	if ! wp_online_check_enabled; then
                WP_STATUS_ONLINE_STATE="disabled"
                return 0
        fi

	if [ "$WP_STATUS_UP" -ne 1 ] && [ "$WP_STATUS_AVAILABLE" -ne 1 ]; then
                WP_STATUS_ONLINE_STATE="offline"
                return 0
        fi

        if [ "$WP_STATUS_DEFAULT_ROUTE" -ne 1 ]; then
                WP_STATUS_ONLINE_STATE="no_route"
                return 0
        fi

        if ! command -v curl >/dev/null 2>&1; then
                WP_STATUS_ONLINE_STATE="unsupported"
                return 0
        fi

        cache_key="$(printf '%s__both' "$iface" | tr -c 'A-Za-z0-9_-' '_')"
        cached_state="$(wp_online_probe_cache_get "$cache_key" 999999 2>/dev/null || true)"
        case "$cached_state" in
                online)
                        WP_STATUS_ONLINE=1
                        WP_STATUS_ONLINE_STATE="online"
                        ;;
                offline)
                        WP_STATUS_ONLINE=0
                        WP_STATUS_ONLINE_STATE="offline"
                        ;;
                *)
                        WP_STATUS_ONLINE=0
                        WP_STATUS_ONLINE_STATE="checking"
                        ;;
        esac
        return 0
}

wp_network_iface_exists() {
	uci -q get "${WP_NETWORK_CONFIG}.$1" >/dev/null 2>&1
}

wp_find_section_by_interface() {
	local config_name="$1"
	local section_type="$2"
	local iface="$3"
	local section current_iface

	for section in $(wp_list_sections "$config_name" "$section_type"); do
		current_iface="$(uci -q get "${config_name}.${section}.interface" 2>/dev/null)"
		if [ "$current_iface" = "$iface" ]; then
			printf '%s\n' "$section"
			return 0
		fi
	done

	return 1
}

wp_get_state_field() {
	local iface="$1"
	local field="$2"
	local section

	section="$(wp_find_section_by_interface "$WP_CONFIG" "state" "$iface")" || return 0
	uci -q get "${WP_CONFIG}.${section}.${field}" 2>/dev/null
}

wp_discovery_zone_for_iface() {
	local iface="$1"
	local section zone_name networks candidate

	for section in $(wp_list_sections "$WP_FIREWALL_CONFIG" "zone"); do
		zone_name="$(uci -q get "${WP_FIREWALL_CONFIG}.${section}.name" 2>/dev/null)"
		networks="$(uci -q get "${WP_FIREWALL_CONFIG}.${section}.network" 2>/dev/null)"

		for candidate in $networks; do
			if [ "$candidate" = "$iface" ]; then
				printf '%s\n' "$zone_name"
				return 0
			fi
		done
	done

	return 1
}

wp_load_candidate_metadata() {
	local iface="$1"
	local origin="$2"
	local section="${3:-}"
	local hidden_value default_order

	default_order="100"
	if [ "$origin" = "manual" ]; then
		default_order="500"
		[ -n "$section" ] || section="$(wp_find_section_by_interface "$WP_CONFIG" "manual" "$iface" 2>/dev/null || true)"
	else
		section="$(wp_find_section_by_interface "$WP_CONFIG" "override" "$iface" 2>/dev/null || true)"
	fi

	WP_CANDIDATE_DISPLAY_NAME=""
	WP_CANDIDATE_HIDDEN="0"
	WP_CANDIDATE_ORDER="$default_order"
	if [ -n "$section" ]; then
		WP_CANDIDATE_DISPLAY_NAME="$(uci -q get "${WP_CONFIG}.${section}.display_name" 2>/dev/null || true)"
		hidden_value="$(uci -q get "${WP_CONFIG}.${section}.hidden" 2>/dev/null || true)"
		WP_CANDIDATE_ORDER="$(uci -q get "${WP_CONFIG}.${section}.order" 2>/dev/null || true)"
		[ -n "$WP_CANDIDATE_ORDER" ] || WP_CANDIDATE_ORDER="$default_order"
		case "$hidden_value" in
			1|true|yes|on) WP_CANDIDATE_HIDDEN="1" ;;
		esac
	fi
	[ -n "$WP_CANDIDATE_DISPLAY_NAME" ] || WP_CANDIDATE_DISPLAY_NAME="$iface"
}

wp_collect_candidates() {
	local discovery_zone seen section zone_name networks iface display_name hidden order warning

	discovery_zone="$(wp_get_discovery_zone)"
	seen=" "

	{
		for section in $(wp_list_sections "$WP_FIREWALL_CONFIG" "zone"); do
			zone_name="$(uci -q get "${WP_FIREWALL_CONFIG}.${section}.name" 2>/dev/null)"
			[ "$zone_name" = "$discovery_zone" ] || continue
			networks="$(uci -q get "${WP_FIREWALL_CONFIG}.${section}.network" 2>/dev/null)"

			for iface in $networks; do
				[ -n "$iface" ] || continue
				case "$seen" in
					*" $iface "*) continue ;;
				esac

				seen="${seen}${iface} "
				wp_load_candidate_metadata "$iface" "auto"
				display_name="$WP_CANDIDATE_DISPLAY_NAME"
				hidden="$WP_CANDIDATE_HIDDEN"
				order="$WP_CANDIDATE_ORDER"
				printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
					"$iface" "auto" "0" "$zone_name" "$display_name" "$hidden" "$order" ""
			done
		done

		for section in $(wp_list_sections "$WP_CONFIG" "manual"); do
			iface="$(uci -q get "${WP_CONFIG}.${section}.interface" 2>/dev/null)"
			[ -n "$iface" ] || continue

			case "$seen" in
				*" $iface "*) continue ;;
			esac

			seen="${seen}${iface} "
			wp_load_candidate_metadata "$iface" "manual" "$section"
			display_name="$WP_CANDIDATE_DISPLAY_NAME"
			hidden="$WP_CANDIDATE_HIDDEN"
			order="$WP_CANDIDATE_ORDER"
			zone_name="$(wp_discovery_zone_for_iface "$iface" 2>/dev/null)"
			warning=""
			if [ -n "$zone_name" ] && [ "$zone_name" != "$discovery_zone" ]; then
				warning="outside_discovery_zone"
			elif [ -z "$zone_name" ]; then
				warning="outside_discovery_zone"
			fi

			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$iface" "manual" "1" "${zone_name:-}" "$display_name" "$hidden" "$order" "$warning"
		done
	} | sort -t "$(printf '\t')" -k7,7n -k1,1
}

wp_get_configured_metric() {
	local value

	value="$(uci -q get "${WP_NETWORK_CONFIG}.$1.metric" 2>/dev/null)"
	if [ -n "$value" ]; then
		printf '%s\n' "$value"
	else
		printf '0\n'
	fi
}

wp_load_iface_status() {
        local iface="$1"
        local include_online_check="${2:-1}"
	local payload route_keys route_key target mask metric address_keys address_key dns_keys dns_key
        local ipaddr prefix gateway4 gateway6

	WP_STATUS_UP=0
	WP_STATUS_AVAILABLE=0
	WP_STATUS_PENDING=0
	WP_STATUS_PROTO=""
	WP_STATUS_DEVICE=""
	WP_STATUS_L3_DEVICE=""
	WP_STATUS_IPV4=""
	WP_STATUS_IPV6=""
	WP_STATUS_DNS=""
	WP_STATUS_GATEWAY=""
	WP_STATUS_DEFAULT_ROUTE=0
	WP_STATUS_EFFECTIVE_METRIC=""
	WP_STATUS_CONFIGURED_METRIC="$(wp_get_configured_metric "$iface")"
	WP_STATUS_SOURCE_IP=""
        WP_STATUS_ONLINE=0
        WP_STATUS_ONLINE_STATE="disabled"

	payload="$(ubus call "network.interface.${iface}" status 2>/dev/null)" || return 1
	[ -n "$payload" ] || return 1

	json_cleanup
	json_load "$payload" || return 1

	json_get_var WP_STATUS_PROTO proto
	json_get_var WP_STATUS_DEVICE device
	json_get_var WP_STATUS_L3_DEVICE l3_device
	json_get_var WP_STATUS_UP up
	json_get_var WP_STATUS_AVAILABLE available
	json_get_var WP_STATUS_PENDING pending

	case "$WP_STATUS_UP" in true|1) WP_STATUS_UP=1 ;; *) WP_STATUS_UP=0 ;; esac
	case "$WP_STATUS_AVAILABLE" in true|1) WP_STATUS_AVAILABLE=1 ;; *) WP_STATUS_AVAILABLE=0 ;; esac
	case "$WP_STATUS_PENDING" in true|1) WP_STATUS_PENDING=1 ;; *) WP_STATUS_PENDING=0 ;; esac

	if json_select "ipv4-address" 2>/dev/null; then
		json_get_keys address_keys
		for address_key in $address_keys; do
			json_select "$address_key"
			json_get_var ipaddr address
			json_get_var prefix mask
			[ -n "$ipaddr" ] && WP_STATUS_IPV4="${WP_STATUS_IPV4}${WP_STATUS_IPV4:+ }${ipaddr}/${prefix}"
			json_select ..
		done
		json_select ..
	fi

	if json_select "ipv6-address" 2>/dev/null; then
		json_get_keys address_keys
		for address_key in $address_keys; do
			json_select "$address_key"
			json_get_var ipaddr address
			json_get_var prefix mask
			[ -n "$ipaddr" ] && WP_STATUS_IPV6="${WP_STATUS_IPV6}${WP_STATUS_IPV6:+ }${ipaddr}/${prefix}"
			json_select ..
		done
		json_select ..
	fi

	if json_select "dns-server" 2>/dev/null; then
		json_get_keys dns_keys
		for dns_key in $dns_keys; do
			json_get_var ipaddr "$dns_key"
			[ -n "$ipaddr" ] && WP_STATUS_DNS="${WP_STATUS_DNS}${WP_STATUS_DNS:+ }${ipaddr}"
		done
		json_select ..
	fi

	if json_select route 2>/dev/null; then
		json_get_keys route_keys
		for route_key in $route_keys; do
			json_select "$route_key"
			json_get_var target target
			json_get_var mask mask
			if [ "$target" = "0.0.0.0" ] && [ "$mask" = "0" ]; then
				json_get_var gateway4 nexthop
				json_get_var metric metric
				WP_STATUS_GATEWAY="${gateway4:-}"
				WP_STATUS_DEFAULT_ROUTE=1
                                WP_STATUS_EFFECTIVE_METRIC="${metric:-}"
				json_select ..
				break
			fi
			json_select ..
		done
		json_select ..
	fi

	if [ "$WP_STATUS_DEFAULT_ROUTE" -eq 0 ] && json_select route6 2>/dev/null; then
		json_get_keys route_keys
		for route_key in $route_keys; do
			json_select "$route_key"
			json_get_var mask mask
			if [ "$mask" = "0" ]; then
				json_get_var target target
				json_get_var gateway6 nexthop
				json_get_var metric metric
				[ -n "$target" ] || target="::"
				WP_STATUS_GATEWAY="${gateway6:-$target}"
				WP_STATUS_DEFAULT_ROUTE=1
                                WP_STATUS_EFFECTIVE_METRIC="${metric:-}"
				json_select ..
				break
			fi
			json_select ..
		done
		json_select ..
	fi

	[ -n "$WP_STATUS_EFFECTIVE_METRIC" ] || WP_STATUS_EFFECTIVE_METRIC="$WP_STATUS_CONFIGURED_METRIC"
        WP_STATUS_SOURCE_IP="$(wp_first_ipv4_from_list "$WP_STATUS_IPV4")"
        if [ "$include_online_check" = "1" ]; then
                wp_resolve_online_state "$iface"
        fi
	return 0
}

wp_compute_summary() {
	local candidates_file="$1"
	local iface origin manual zone display_name hidden order warning
	local effective_metric

	WP_SUMMARY_ACTIVE_STATE="none"
	WP_SUMMARY_ACTIVE_IFACE=""
	WP_SUMMARY_ACTIVE_METRIC=""
	WP_SUMMARY_ACTIVE_COUNT=0

	while IFS='	' read -r iface origin manual zone display_name hidden order warning; do
		[ -n "$iface" ] || continue
		[ "$hidden" = "1" ] && continue
		wp_network_iface_exists "$iface" || continue
                wp_load_iface_status "$iface" 0 || continue
		[ "$WP_STATUS_DEFAULT_ROUTE" -eq 1 ] || continue

		effective_metric="${WP_STATUS_EFFECTIVE_METRIC:-0}"
		if [ -z "$WP_SUMMARY_ACTIVE_METRIC" ] || [ "$effective_metric" -lt "$WP_SUMMARY_ACTIVE_METRIC" ]; then
			WP_SUMMARY_ACTIVE_METRIC="$effective_metric"
			WP_SUMMARY_ACTIVE_IFACE="$iface"
			WP_SUMMARY_ACTIVE_COUNT=1
		elif [ "$effective_metric" -eq "$WP_SUMMARY_ACTIVE_METRIC" ]; then
			WP_SUMMARY_ACTIVE_COUNT=$((WP_SUMMARY_ACTIVE_COUNT + 1))
		fi
	done < "$candidates_file"

	if [ -z "$WP_SUMMARY_ACTIVE_METRIC" ]; then
		WP_SUMMARY_ACTIVE_STATE="none"
	elif [ "$WP_SUMMARY_ACTIVE_COUNT" -gt 1 ]; then
		WP_SUMMARY_ACTIVE_STATE="multiple"
		WP_SUMMARY_ACTIVE_IFACE=""
	else
		WP_SUMMARY_ACTIVE_STATE="active"
	fi
}

wp_json_add_string_list() {
	local key="$1"
	local items="$2"
	local item

	json_add_array "$key"
	for item in $items; do
		json_add_string "" "$item"
	done
	json_close_array
}

wp_render_status_json() {
        local candidates_file status_file
	local iface origin manual zone display_name hidden order warning
        local configured_metric active_flag equal_flag configured
        local proto device l3_device effective_metric gateway up available pending default_route
        local ipv4_serialized ipv6_serialized dns_serialized field_sep list_sep
        local online_flag online_state

	candidates_file="$(mktemp)" || return 1
        status_file="$(mktemp)" || {
                rm -f "$candidates_file"
                return 1
        }
        field_sep="$(printf '\034')"
	list_sep="$(printf '\035')"
	wp_collect_candidates > "$candidates_file"
	WP_SUMMARY_ACTIVE_STATE="none"
	WP_SUMMARY_ACTIVE_IFACE=""
	WP_SUMMARY_ACTIVE_METRIC=""
	WP_SUMMARY_ACTIVE_COUNT=0

	while IFS='	' read -r iface origin manual zone display_name hidden order warning; do
		[ -n "$iface" ] || continue

		configured=0
		if wp_load_iface_status "$iface"; then
			configured=1
		else
			WP_STATUS_UP=0
			WP_STATUS_AVAILABLE=0
			WP_STATUS_PENDING=0
			WP_STATUS_PROTO=""
			WP_STATUS_DEVICE=""
			WP_STATUS_L3_DEVICE=""
			WP_STATUS_IPV4=""
			WP_STATUS_IPV6=""
			WP_STATUS_DNS=""
			WP_STATUS_GATEWAY=""
			WP_STATUS_DEFAULT_ROUTE=0
			WP_STATUS_EFFECTIVE_METRIC=""
                        WP_STATUS_ONLINE=0
                        WP_STATUS_ONLINE_STATE="offline"
		fi

		configured_metric="${WP_STATUS_CONFIGURED_METRIC:-0}"
		proto="${WP_STATUS_PROTO:-}"
                device="${WP_STATUS_DEVICE:-}"
                l3_device="${WP_STATUS_L3_DEVICE:-}"
                effective_metric="${WP_STATUS_EFFECTIVE_METRIC:-}"
                gateway="${WP_STATUS_GATEWAY:-}"
                up="${WP_STATUS_UP:-0}"
                available="${WP_STATUS_AVAILABLE:-0}"
                pending="${WP_STATUS_PENDING:-0}"
		default_route="${WP_STATUS_DEFAULT_ROUTE:-0}"
		online_flag="${WP_STATUS_ONLINE:-0}"
		online_state="${WP_STATUS_ONLINE_STATE:-offline}"
		if [ "$hidden" != "1" ] && [ "$configured" -eq 1 ] && [ "$default_route" -eq 1 ]; then
			if [ -z "$WP_SUMMARY_ACTIVE_METRIC" ] || [ "${effective_metric:-0}" -lt "$WP_SUMMARY_ACTIVE_METRIC" ]; then
				WP_SUMMARY_ACTIVE_METRIC="${effective_metric:-0}"
				WP_SUMMARY_ACTIVE_IFACE="$iface"
				WP_SUMMARY_ACTIVE_COUNT=1
			elif [ "${effective_metric:-0}" -eq "$WP_SUMMARY_ACTIVE_METRIC" ]; then
				WP_SUMMARY_ACTIVE_COUNT=$((WP_SUMMARY_ACTIVE_COUNT + 1))
			fi
		fi
                ipv4_serialized="$(printf '%s' "${WP_STATUS_IPV4:-}" | tr ' ' "$list_sep")"
                ipv6_serialized="$(printf '%s' "${WP_STATUS_IPV6:-}" | tr ' ' "$list_sep")"
                dns_serialized="$(printf '%s' "${WP_STATUS_DNS:-}" | tr ' ' "$list_sep")"

                {
                        printf '%s' "$iface"
                        printf '%s%s' "$field_sep" "$display_name"
                        printf '%s%s' "$field_sep" "$origin"
                        printf '%s%s' "$field_sep" "$manual"
                        printf '%s%s' "$field_sep" "$configured"
                        printf '%s%s' "$field_sep" "$hidden"
                        printf '%s%s' "$field_sep" "$zone"
                        printf '%s%s' "$field_sep" "$proto"
                        printf '%s%s' "$field_sep" "$device"
                        printf '%s%s' "$field_sep" "$l3_device"
                        printf '%s%s' "$field_sep" "$configured_metric"
                        printf '%s%s' "$field_sep" "$effective_metric"
                        printf '%s%s' "$field_sep" "$gateway"
                        printf '%s%s' "$field_sep" "$up"
                        printf '%s%s' "$field_sep" "$available"
                        printf '%s%s' "$field_sep" "$pending"
                        printf '%s%s' "$field_sep" "$default_route"
			printf '%s0' "$field_sep"
			printf '%s0' "$field_sep"
                        printf '%s%s' "$field_sep" "$online_flag"
                        printf '%s%s' "$field_sep" "$online_state"
                        printf '%s%s' "$field_sep" "$ipv4_serialized"
                        printf '%s%s' "$field_sep" "$ipv6_serialized"
                        printf '%s%s' "$field_sep" "$dns_serialized"
                        printf '%s%s\n' "$field_sep" "$warning"
                } >> "$status_file"
        done < "$candidates_file"

	if [ -z "$WP_SUMMARY_ACTIVE_METRIC" ]; then
		WP_SUMMARY_ACTIVE_STATE="none"
	elif [ "$WP_SUMMARY_ACTIVE_COUNT" -gt 1 ]; then
		WP_SUMMARY_ACTIVE_STATE="multiple"
		WP_SUMMARY_ACTIVE_IFACE=""
	else
		WP_SUMMARY_ACTIVE_STATE="active"
	fi

        json_init
        json_add_boolean "ok" 1
        json_add_string "active_state" "$WP_SUMMARY_ACTIVE_STATE"
	json_add_string "active_interface" "$WP_SUMMARY_ACTIVE_IFACE"
	json_add_string "active_metric" "${WP_SUMMARY_ACTIVE_METRIC:-}"
	json_add_boolean "service_running" "$(wp_service_running_flag)"
	json_add_boolean "online_check_enabled" "$(wp_online_check_enabled_flag)"
        json_add_boolean "online_check_supported" "$(wp_online_check_supported_flag)"
        json_add_string "online_check_url" "$(wp_get_online_check_url)"
        json_add_int "online_check_interval" "$(wp_get_online_check_interval)"
        json_add_int "online_check_timeout" "$(wp_get_online_check_timeout)"
        json_add_array "interfaces"
        while IFS="$field_sep" read -r iface display_name origin manual configured hidden zone proto device l3_device configured_metric effective_metric gateway up available pending default_route active_flag equal_flag online_flag online_state ipv4_serialized ipv6_serialized dns_serialized warning; do
		active_flag=0
		equal_flag=0
		if [ "$WP_SUMMARY_ACTIVE_STATE" = "active" ] && [ "$WP_SUMMARY_ACTIVE_IFACE" = "$iface" ]; then
			active_flag=1
		elif [ "$WP_SUMMARY_ACTIVE_STATE" = "multiple" ] && [ "$default_route" -eq 1 ] && \
			[ "${effective_metric:-}" = "${WP_SUMMARY_ACTIVE_METRIC:-}" ]; then
			equal_flag=1
		fi

		json_add_object ""
		json_add_string "name" "$iface"
		json_add_string "display_name" "$display_name"
                json_add_string "origin" "$origin"
		json_add_boolean "manual" "$manual"
		json_add_boolean "configured" "$configured"
                json_add_boolean "hidden" "$hidden"
		json_add_string "zone" "$zone"
                json_add_string "proto" "$proto"
                json_add_string "device" "$device"
                json_add_string "l3_device" "$l3_device"
		json_add_string "configured_metric" "$configured_metric"
                json_add_string "effective_metric" "$effective_metric"
                json_add_string "gateway" "$gateway"
                json_add_boolean "up" "$up"
                json_add_boolean "available" "$available"
                json_add_boolean "pending" "$pending"
                json_add_boolean "default_route" "$default_route"
		json_add_boolean "active" "$active_flag"
		json_add_boolean "equal_priority" "$equal_flag"
                json_add_boolean "online" "$online_flag"
                json_add_string "online_state" "$online_state"
                wp_json_add_string_list "ipv4" "$(printf '%s' "$ipv4_serialized" | tr "$list_sep" ' ')"
                wp_json_add_string_list "ipv6" "$(printf '%s' "$ipv6_serialized" | tr "$list_sep" ' ')"
                wp_json_add_string_list "dns" "$(printf '%s' "$dns_serialized" | tr "$list_sep" ' ')"
		json_add_array "warnings"
		if [ -n "$warning" ]; then
			json_add_string "" "$warning"
		fi
		json_close_array
		json_close_object
        done < "$status_file"

	json_close_array
	json_dump
        rm -f "$candidates_file" "$status_file"
}

wp_render_status_text() {
	local candidates_file
	local iface origin manual zone display_name hidden order warning configured_metric marker

	candidates_file="$(mktemp)" || return 1
	wp_collect_candidates > "$candidates_file"
	wp_compute_summary "$candidates_file"

	printf 'State: %s\n' "$WP_SUMMARY_ACTIVE_STATE"
	printf 'Service: %s\n' "$([ "$(wp_service_running_flag)" = "1" ] && printf 'running' || printf 'stopped')"
	printf 'Active: %s\n' "${WP_SUMMARY_ACTIVE_IFACE:-none}"
	printf 'Metric: %s\n' "${WP_SUMMARY_ACTIVE_METRIC:-n/a}"
	printf '\nCandidates:\n'

	while IFS='	' read -r iface origin manual zone display_name hidden order warning; do
		[ -n "$iface" ] || continue
		[ "$hidden" = "1" ] && continue
		configured_metric="$(wp_get_configured_metric "$iface")"
                wp_load_iface_status "$iface" || true
		marker=" "
		if [ "$WP_SUMMARY_ACTIVE_STATE" = "active" ] && [ "$WP_SUMMARY_ACTIVE_IFACE" = "$iface" ]; then
			marker="*"
		elif [ "$WP_SUMMARY_ACTIVE_STATE" = "multiple" ] && [ "${WP_STATUS_EFFECTIVE_METRIC:-}" = "${WP_SUMMARY_ACTIVE_METRIC:-}" ]; then
			marker="="
		fi

                printf '%s %s (%s) proto=%s cfg_metric=%s eff_metric=%s up=%s route=%s online=%s\n' \
			"$marker" "$display_name" "$iface" "${WP_STATUS_PROTO:-?}" "$configured_metric" \
                        "${WP_STATUS_EFFECTIVE_METRIC:-?}" "$WP_STATUS_UP" "$WP_STATUS_DEFAULT_ROUTE" "$WP_STATUS_ONLINE_STATE"
	done < "$candidates_file"

	rm -f "$candidates_file"
}

wp_render_discover_json() {
	local candidates_file iface origin manual zone display_name hidden order warning

	candidates_file="$(mktemp)" || return 1
	wp_collect_candidates > "$candidates_file"

	json_init
	json_add_boolean "ok" 1
	json_add_array "interfaces"
	while IFS='	' read -r iface origin manual zone display_name hidden order warning; do
		[ -n "$iface" ] || continue
		[ "$hidden" = "1" ] && continue
		json_add_object ""
		json_add_string "name" "$iface"
		json_add_string "display_name" "$display_name"
		json_add_string "origin" "$origin"
		json_add_boolean "manual" "$manual"
		json_add_string "zone" "$zone"
		json_add_string "order" "$order"
		json_add_array "warnings"
		if [ -n "$warning" ]; then
			json_add_string "" "$warning"
		fi
		json_close_array
		json_close_object
	done < "$candidates_file"
	json_close_array
	json_dump

	rm -f "$candidates_file"
}

wp_probe_target_url() {
	local target="$1"
	case "$target" in
		google) printf '%s\n' "$WP_ONLINE_PROBE_TARGET_GOOGLE" ;;
		yandex) printf '%s\n' "$WP_ONLINE_PROBE_TARGET_YANDEX" ;;
		generate_204|default|wanpilot) printf '%s\n' "$(wp_get_online_check_url)" ;;
		*) printf '%s\n' "" ;;
	esac
}

wp_render_probe_json() {
	local iface="$1"
	local target="${2:-both}"
	local source_ip=""
	local bind_iface=""
	local timeout
	local include_google=0 include_yandex=0 include_default=0
	local name url raw_out http_code rtt_ms ok
	local google_ok=0 yandex_ok=0

	[ -n "$iface" ] || {
		json_init
		json_add_boolean "ok" 0
		json_add_string "error" "missing_interface"
		json_dump
		return 1
	}

	if [ "$(wp_service_running_flag)" != "1" ]; then
		json_init
		json_add_boolean "ok" 0
		json_add_string "error" "service_stopped"
		json_dump
		return 1
	fi

	if ! command -v curl >/dev/null 2>&1; then
		json_init
		json_add_boolean "ok" 0
		json_add_string "error" "curl_not_installed"
		json_dump
		return 1
	fi

	if wp_network_iface_exists "$iface"; then
		wp_load_iface_status "$iface" 0 2>/dev/null || true
		source_ip="$WP_STATUS_SOURCE_IP"
		bind_iface="${WP_STATUS_L3_DEVICE:-$iface}"
	else
		bind_iface="$iface"
	fi

	case "$target" in
		google) include_google=1 ;;
		yandex) include_yandex=1 ;;
		default|generate_204|wanpilot) include_default=1 ;;
		both|all|"")
			include_google=1
			include_yandex=1
			;;
		*)
			json_init
			json_add_boolean "ok" 0
			json_add_string "error" "unknown_target"
			json_add_string "target" "$target"
			json_dump
			return 1
			;;
	esac

	timeout="$(wp_get_online_check_timeout)"

	json_init
	json_add_boolean "ok" 1
	json_add_string "interface" "$iface"
	json_add_string "source_ip" "$source_ip"
	json_add_string "target" "$target"
	json_add_int "timeout" "$timeout"
	json_add_array "results"

	if [ "$include_default" -eq 1 ]; then
		name="wanpilot"
		url="$(wp_probe_target_url "default")"
		if [ -n "$url" ]; then
			raw_out="$(wp_curl_probe_target "$bind_iface" "$url" "$timeout" 2>/dev/null || true)"
			http_code="${raw_out%% *}"
			rtt_ms="${raw_out##* }"
			[ -n "$rtt_ms" ] || rtt_ms=0
			case "$http_code" in
				200|201|202|203|204|205|206|301|302|304|307|308) ok=1 ;;
				*) ok=0 ;;
			esac
			json_add_object ""
			json_add_string "name" "$name"
			json_add_string "url" "$url"
			json_add_boolean "ok" "$ok"
			json_add_string "http_code" "$http_code"
			json_add_int "rtt_ms" "${rtt_ms:-0}"
			json_close_object
		fi
	fi

	if [ "$include_google" -eq 1 ]; then
		name="google"
		url="$(wp_probe_target_url "google")"
		raw_out="$(wp_curl_probe_target "$bind_iface" "$url" "$timeout" 2>/dev/null || true)"
		http_code="${raw_out%% *}"
		rtt_ms="${raw_out##* }"
		[ -n "$rtt_ms" ] || rtt_ms=0
		case "$http_code" in
			200|201|202|203|204|205|206|301|302|304|307|308) ok=1 ;;
			*) ok=0 ;;
		esac
		google_ok="$ok"
		json_add_object ""
		json_add_string "name" "$name"
		json_add_string "url" "$url"
		json_add_boolean "ok" "$ok"
		json_add_string "http_code" "$http_code"
		json_add_int "rtt_ms" "${rtt_ms:-0}"
		json_close_object
	fi

	if [ "$include_yandex" -eq 1 ]; then
		name="yandex"
		url="$(wp_probe_target_url "yandex")"
		raw_out="$(wp_curl_probe_target "$bind_iface" "$url" "$timeout" 2>/dev/null || true)"
		http_code="${raw_out%% *}"
		rtt_ms="${raw_out##* }"
		[ -n "$rtt_ms" ] || rtt_ms=0
		case "$http_code" in
			200|201|202|203|204|205|206|301|302|304|307|308) ok=1 ;;
			*) ok=0 ;;
		esac
		yandex_ok="$ok"
		json_add_object ""
		json_add_string "name" "$name"
		json_add_string "url" "$url"
		json_add_boolean "ok" "$ok"
		json_add_string "http_code" "$http_code"
		json_add_int "rtt_ms" "${rtt_ms:-0}"
		json_close_object
	fi

	json_close_array
	json_dump

	if [ "$include_google" -eq 1 ]; then
		wp_online_probe_record_result "$iface" "google" "$google_ok"
	fi
	if [ "$include_yandex" -eq 1 ]; then
		wp_online_probe_record_result "$iface" "yandex" "$yandex_ok"
	fi
}

wp_set_metric_value() {
	local iface="$1"
	local value="$2"

	if [ -n "$value" ] && [ "$value" != "0" ]; then
		uci -q set "${WP_NETWORK_CONFIG}.${iface}.metric=${value}"
	else
		uci -q delete "${WP_NETWORK_CONFIG}.${iface}.metric" 2>/dev/null || true
	fi
}

wp_reload_network() {
	ubus call network reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1
}

wp_verify_active_iface() {
	local expected_iface="$1"
	local attempts="${2:-5}"
	local i
	local candidates_file

	candidates_file="$(mktemp)" || return 1
	wp_collect_candidates > "$candidates_file"

	i=0
	while [ "$i" -lt "$attempts" ]; do
		wp_compute_summary "$candidates_file"
		if [ "$WP_SUMMARY_ACTIVE_STATE" = "active" ] && [ "$WP_SUMMARY_ACTIVE_IFACE" = "$expected_iface" ]; then
			rm -f "$candidates_file"
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done

	rm -f "$candidates_file"
	return 1
}

wp_ensure_state_section() {
	local iface="$1"
	local section

	section="$(wp_find_section_by_interface "$WP_CONFIG" "state" "$iface")" || true
	if [ -n "$section" ]; then
		printf '%s\n' "$section"
		return 0
	fi

	section="$(uci add "$WP_CONFIG" state)"
	uci -q set "${WP_CONFIG}.${section}.interface=${iface}"
	printf '%s\n' "$section"
}

wp_record_state_metrics() {
	local iface="$1"
	local baseline="$2"
	local managed="$3"
	local section

	section="$(wp_ensure_state_section "$iface")"
	uci -q set "${WP_CONFIG}.${section}.baseline_metric=${baseline}"
	uci -q set "${WP_CONFIG}.${section}.managed_metric=${managed}"
}

wp_resolve_baseline_metric() {
	local iface="$1"
	local current_metric="$2"
	local baseline managed

	baseline="$(wp_get_state_field "$iface" "baseline_metric")"
	managed="$(wp_get_state_field "$iface" "managed_metric")"

	if [ -n "$managed" ] && [ "$current_metric" != "$managed" ]; then
		printf '%s\n' "$current_metric"
	elif [ -n "$baseline" ]; then
		printf '%s\n' "$baseline"
	else
		printf '%s\n' "$current_metric"
	fi
}

wp_switch_iface() {
	local target_iface="$1"
	local output_json="${2:-0}"
	local candidates_file snapshot_file computed_file
	local iface origin manual zone display_name hidden order warning
	local target_found target_usable preferred_metric non_target_base
	local current_metric baseline_metric max_baseline index managed_metric

	target_found=0
	target_usable=0
	max_baseline=0
	index=0

	candidates_file="$(mktemp)" || return 1
	snapshot_file="$(mktemp)" || {
		rm -f "$candidates_file"
		return 1
	}
	computed_file="$(mktemp)" || {
		rm -f "$candidates_file" "$snapshot_file"
		return 1
	}

	wp_collect_candidates > "$candidates_file"

	while IFS='	' read -r iface origin manual zone display_name hidden order warning; do
		[ -n "$iface" ] || continue
		[ "$hidden" = "1" ] && continue
		wp_network_iface_exists "$iface" || continue

		current_metric="$(wp_get_configured_metric "$iface")"
		printf '%s\t%s\n' "$iface" "$current_metric" >> "$snapshot_file"

		baseline_metric="$(wp_resolve_baseline_metric "$iface" "$current_metric")"
		if [ "$baseline_metric" -gt "$max_baseline" ] 2>/dev/null; then
			max_baseline="$baseline_metric"
		fi

		if [ "$iface" = "$target_iface" ]; then
			target_found=1
                        wp_load_iface_status "$iface" 0 || true
			if [ "$WP_STATUS_DEFAULT_ROUTE" -eq 1 ]; then
				target_usable=1
			fi
		fi

		printf '%s\t%s\t%s\n' "$iface" "$current_metric" "$baseline_metric" >> "$computed_file"
	done < "$candidates_file"

	if [ "$target_found" -ne 1 ]; then
		rm -f "$candidates_file" "$snapshot_file" "$computed_file"
		if [ "$output_json" -eq 1 ]; then
			json_init
			json_add_boolean "ok" 0
			json_add_string "error" "unknown_interface"
			json_dump
		else
			printf 'Target interface is not part of the WANPilot pool.\n' >&2
		fi
		return 1
	fi

	if [ "$target_usable" -ne 1 ]; then
		rm -f "$candidates_file" "$snapshot_file" "$computed_file"
		if [ "$output_json" -eq 1 ]; then
			json_init
			json_add_boolean "ok" 0
			json_add_string "error" "target_has_no_default_route"
			json_dump
		else
			printf 'Target interface has no usable default route right now.\n' >&2
		fi
		return 1
	fi

	preferred_metric="$(wp_get_preferred_metric)"
	non_target_base=$((max_baseline + 100))
	index=0

	while IFS='	' read -r iface current_metric baseline_metric; do
		[ -n "$iface" ] || continue
		if [ "$iface" = "$target_iface" ]; then
			wp_set_metric_value "$iface" "$preferred_metric"
		else
			managed_metric=$((non_target_base + index))
			wp_set_metric_value "$iface" "$managed_metric"
			index=$((index + 1))
		fi
	done < "$computed_file"

	uci commit "$WP_NETWORK_CONFIG"
	wp_reload_network

	if ! wp_verify_active_iface "$target_iface" 6; then
		while IFS='	' read -r iface current_metric; do
			[ -n "$iface" ] || continue
			wp_set_metric_value "$iface" "$current_metric"
		done < "$snapshot_file"
		uci commit "$WP_NETWORK_CONFIG"
		wp_reload_network

		rm -f "$candidates_file" "$snapshot_file" "$computed_file"
		if [ "$output_json" -eq 1 ]; then
			json_init
			json_add_boolean "ok" 0
			json_add_string "error" "verification_failed"
			json_dump
		else
			printf 'Switch verification failed and previous metrics were restored.\n' >&2
		fi
		return 1
	fi

	index=0
	while IFS='	' read -r iface current_metric baseline_metric; do
		[ -n "$iface" ] || continue
		if [ "$iface" = "$target_iface" ]; then
			wp_record_state_metrics "$iface" "$baseline_metric" "$preferred_metric"
		else
			managed_metric=$((non_target_base + index))
			wp_record_state_metrics "$iface" "$baseline_metric" "$managed_metric"
			index=$((index + 1))
		fi
	done < "$computed_file"
	uci commit "$WP_CONFIG"

	rm -f "$candidates_file" "$snapshot_file" "$computed_file"
	if [ "$output_json" -eq 1 ]; then
		json_init
		json_add_boolean "ok" 1
		json_add_string "requested_interface" "$target_iface"
		json_add_string "active_interface" "$target_iface"
		json_dump
	else
		printf 'Preferred uplink switched to %s.\n' "$target_iface"
	fi
	return 0
}

wp_config_get_json() {
	local section iface display_name hidden order baseline managed

	json_init
	json_add_boolean "ok" 1
	json_add_string "discovery_zone" "$(wp_get_discovery_zone)"
	json_add_string "preferred_metric" "$(wp_get_preferred_metric)"
        json_add_string "online_check_enabled" "$(wp_online_check_enabled_flag)"
        json_add_string "online_check_url" "$(wp_get_online_check_url)"
	json_add_string "online_check_interval" "$(wp_get_online_check_interval)"
        json_add_string "online_check_timeout" "$(wp_get_online_check_timeout)"

	json_add_array "manual"
	for section in $(wp_list_sections "$WP_CONFIG" "manual"); do
		iface="$(uci -q get "${WP_CONFIG}.${section}.interface" 2>/dev/null)"
		display_name="$(uci -q get "${WP_CONFIG}.${section}.display_name" 2>/dev/null)"
		hidden="$(uci -q get "${WP_CONFIG}.${section}.hidden" 2>/dev/null)"
		order="$(uci -q get "${WP_CONFIG}.${section}.order" 2>/dev/null)"
		json_add_object ""
		json_add_string "interface" "$iface"
		json_add_string "display_name" "$display_name"
		json_add_string "hidden" "${hidden:-0}"
		json_add_string "order" "${order:-500}"
		json_close_object
	done
	json_close_array

	json_add_array "overrides"
	for section in $(wp_list_sections "$WP_CONFIG" "override"); do
		iface="$(uci -q get "${WP_CONFIG}.${section}.interface" 2>/dev/null)"
		display_name="$(uci -q get "${WP_CONFIG}.${section}.display_name" 2>/dev/null)"
		hidden="$(uci -q get "${WP_CONFIG}.${section}.hidden" 2>/dev/null)"
		order="$(uci -q get "${WP_CONFIG}.${section}.order" 2>/dev/null)"
		json_add_object ""
		json_add_string "interface" "$iface"
		json_add_string "display_name" "$display_name"
		json_add_string "hidden" "${hidden:-0}"
		json_add_string "order" "${order:-100}"
		json_close_object
	done
	json_close_array

	json_add_array "state"
	for section in $(wp_list_sections "$WP_CONFIG" "state"); do
		iface="$(uci -q get "${WP_CONFIG}.${section}.interface" 2>/dev/null)"
		baseline="$(uci -q get "${WP_CONFIG}.${section}.baseline_metric" 2>/dev/null)"
		managed="$(uci -q get "${WP_CONFIG}.${section}.managed_metric" 2>/dev/null)"
		json_add_object ""
		json_add_string "interface" "$iface"
		json_add_string "baseline_metric" "$baseline"
		json_add_string "managed_metric" "$managed"
		json_close_object
	done
	json_close_array

	json_dump
}

wp_config_set_zone() {
	uci -q set "${WP_CONFIG}.main.discovery_zone=$1"
	uci commit "$WP_CONFIG"
	wp_mark_online_backend_dirty
	wp_sync_pingcheck_config >/dev/null 2>&1 || true
}

wp_config_add_manual() {
	local iface="$1"
	local display_name="$2"
	local section

	section="$(wp_find_section_by_interface "$WP_CONFIG" "manual" "$iface")" || true
	if [ -z "$section" ]; then
		section="$(uci add "$WP_CONFIG" manual)"
	fi

	uci -q set "${WP_CONFIG}.${section}.interface=${iface}"
	[ -n "$display_name" ] && uci -q set "${WP_CONFIG}.${section}.display_name=${display_name}"
	uci commit "$WP_CONFIG"
	wp_mark_online_backend_dirty
	wp_sync_pingcheck_config >/dev/null 2>&1 || true
}

wp_config_remove_manual() {
	local iface="$1"
	local section

	section="$(wp_find_section_by_interface "$WP_CONFIG" "manual" "$iface")" || return 1
	uci -q delete "${WP_CONFIG}.${section}"
	uci commit "$WP_CONFIG"
	wp_mark_online_backend_dirty
	wp_sync_pingcheck_config >/dev/null 2>&1 || true
}

wp_ensure_override_section() {
	local iface="$1"
	local section

	section="$(wp_find_section_by_interface "$WP_CONFIG" "override" "$iface")" || true
	if [ -n "$section" ]; then
		printf '%s\n' "$section"
		return 0
	fi

	section="$(uci add "$WP_CONFIG" override)"
	uci -q set "${WP_CONFIG}.${section}.interface=${iface}"
	printf '%s\n' "$section"
}

wp_config_set_metadata_field() {
	local iface="$1"
	local field="$2"
	local value="$3"
	local section

        section="$(wp_find_section_by_interface "$WP_CONFIG" "manual" "$iface")" || true
        if [ -z "$section" ]; then
                section="$(wp_ensure_override_section "$iface")"
        fi

	uci -q set "${WP_CONFIG}.${section}.${field}=${value}"
	uci commit "$WP_CONFIG"
	wp_mark_online_backend_dirty
	wp_sync_pingcheck_config >/dev/null 2>&1 || true
}
