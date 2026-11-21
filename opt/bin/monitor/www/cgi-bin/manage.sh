#!/bin/sh
# Management API for KVAS Web UI v2
# Actions: auth, hosts, vpn, upgrade, backup, restore, update, …

PASS_FILE=/opt/kvas_web_pass
TOKEN_DIR=/tmp/kvas_web_tokens
KVAS_BIN=/opt/apps/kvas/bin/kvas
UPGRADE_LOG=/tmp/kvas-web-upgrade.log
BYPASS_CHECK_BIN=/opt/apps/kvas/bin/monitor/bypass_check.sh
BYPASS_CHECK_LOCK=/tmp/kvas-bypass-check.lock
BYPASS_CHECK_LOCK_DIR=/tmp/kvas-bypass-check.lock.d
BYPASS_CHECK_PID=/tmp/kvas-bypass-check.pid
BYPASS_CHECK_RESULT=/tmp/kvas-bypass-check.json
BYPASS_CHECK_PROGRESS=/tmp/kvas-bypass-check.progress
BYPASS_CHECK_LOG=/tmp/kvas-bypass-check.log
KVAS_LIST=/opt/etc/kvas.list
KVAS_CONF_FILE=/opt/etc/kvas.conf
CONF_LOCK_DIR=/tmp/kvas_conf.lock
IOT_LOCKDOWN_LIST=/opt/etc/kvas-iot-lockdown.list
IOT_LOCKDOWN_HOOK=/opt/etc/ndm/netfilter.d/090-iot-lockdown
PARENTAL_LIST=/opt/etc/adblock/block.list
ADGUARD_WEB_PID=/tmp/kvas-adguard-web.pid
ADGUARD_WEB_LOG=/tmp/kvas-adguard-web.log
ADGUARD_WEB_BACKUP=/opt/kvas_backup/web-adguard-dns

# JSON-экранирование строки внутри awk: посимвольно, т.к. экранирование в замене gsub
# у busybox awk и mawk разное (прежний gsub в busybox оставлял кавычку неэкранированной).
# Управляющие символы → пробел.
AWK_JESC='function jesc(s,  o, i, c) { o = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "\\" || c == "\"") o = o "\\" c; else if (c < " ") o = o " "; else o = o c } return o }
'

json_str() { printf '%s' "$1" | jq -Rs '.' 2>/dev/null || printf '"%s"' "$1" | sed 's/"/\\"/g'; }
json_error() { printf '{"error":%s}\n' "$(json_str "$1")"; exit 0; }
json_ok()    { printf '{"ok":true,"msg":%s}\n' "$(json_str "$1")"; exit 0; }

adguard_active() {
	[ -x /opt/etc/init.d/S99adguardhome ] && /opt/etc/init.d/S99adguardhome status 2>/dev/null | grep -q alive
}

adguard_setup_running() {
	local pid
	pid=$(cat "$ADGUARD_WEB_PID" 2>/dev/null)
	case "$pid" in *[!0-9]*|'') return 1 ;; esac
	[ -r "/proc/$pid/cmdline" ] && tr '\000' ' ' < "/proc/$pid/cmdline" | grep -q '[k]vas adguard on web'
}

adguard_status_json() {
	if adguard_active; then
		echo '{"ok":true,"adguard":"on"}'
	elif adguard_setup_running; then
		echo '{"ok":true,"adguard":"setup"}'
	elif [ -x /opt/bin/AdGuardHome ]; then
		echo '{"ok":true,"adguard":"off"}'
	else
		echo '{"ok":true,"adguard":"not_installed"}'
	fi
}

adguard_backup_file() {
	local source="$1" name="$2"
	if [ -e "$source" ]; then
		cp -pf "$source" "$ADGUARD_WEB_BACKUP/$name"
		rm -f "$ADGUARD_WEB_BACKUP/$name.absent"
	else
		rm -f "$ADGUARD_WEB_BACKUP/$name"
		: > "$ADGUARD_WEB_BACKUP/$name.absent"
	fi
}

adguard_web_backup() {
	mkdir -p "$ADGUARD_WEB_BACKUP" || return 1
	adguard_backup_file /opt/etc/kvas.conf kvas.conf || return 1
	adguard_backup_file /opt/etc/dnsmasq.conf dnsmasq.conf || return 1
	adguard_backup_file /opt/etc/init.d/S56dnsmasq S56dnsmasq || return 1
	adguard_backup_file /opt/etc/init.d/S09dnscrypt-proxy2 S09dnscrypt-proxy2 || return 1
	adguard_backup_file /opt/etc/init.d/S96kvas S96kvas || return 1
	adguard_backup_file /opt/etc/init.d/S99adguardhome S99adguardhome || return 1
}

adguard_restore_file() {
	local target="$1" name="$2"
	if [ -f "$ADGUARD_WEB_BACKUP/$name.absent" ]; then
		rm -f "$target"
	elif [ -f "$ADGUARD_WEB_BACKUP/$name" ]; then
		cp -pf "$ADGUARD_WEB_BACKUP/$name" "$target"
	else
		return 1
	fi
}

# Restore the exact DNS/init state captured immediately before the Web UI
# switch. It deliberately does not call the legacy `kvas adguard off`, which
# regenerates dnsmasq.conf and can discard a user's DNS configuration.
adguard_web_restore() {
	local pid
	if adguard_setup_running; then
		pid=$(cat "$ADGUARD_WEB_PID")
		kill "$pid" 2>/dev/null || true
	fi
	[ -x /opt/etc/init.d/S99adguardhome ] && /opt/etc/init.d/S99adguardhome stop >/dev/null 2>&1 || true
	pidof AdGuardHome >/dev/null 2>&1 && killall AdGuardHome >/dev/null 2>&1 || true
	[ -d "$ADGUARD_WEB_BACKUP" ] || return 1
	adguard_restore_file /opt/etc/kvas.conf kvas.conf || return 1
	adguard_restore_file /opt/etc/dnsmasq.conf dnsmasq.conf || return 1
	adguard_restore_file /opt/etc/init.d/S56dnsmasq S56dnsmasq || return 1
	adguard_restore_file /opt/etc/init.d/S09dnscrypt-proxy2 S09dnscrypt-proxy2 || return 1
	adguard_restore_file /opt/etc/init.d/S96kvas S96kvas || return 1
	adguard_restore_file /opt/etc/init.d/S99adguardhome S99adguardhome || return 1
	[ -x /opt/etc/init.d/S56dnsmasq ] && /opt/etc/init.d/S56dnsmasq restart >/dev/null 2>&1 || return 1
	[ -x /opt/etc/init.d/S09dnscrypt-proxy2 ] && /opt/etc/init.d/S09dnscrypt-proxy2 restart >/dev/null 2>&1 || true
	type=iptables table=mangle /opt/etc/ndm/netfilter.d/100-vpn-mark >/dev/null 2>&1 || true
	[ -x /opt/etc/init.d/S99kvas-awg-route ] && /opt/etc/init.d/S99kvas-awg-route restart >/dev/null 2>&1 || true
	rm -f "$ADGUARD_WEB_PID"
}

normalize_domain() {
	domain=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	case "$domain" in \*.*) domain=${domain#\*.} ;; esac
	domain=${domain%.}
	printf '%s\n' "$domain"
}

valid_domain() {
	case "$1" in ''|.*|*.|*..*|*[!a-z0-9.-]*) return 1 ;; esac
	printf '%s\n' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
}

# MAC в нижнем регистре (нормализованный) либо пусто при некорректном вводе.
normalize_mac() {
	# многострочный ввод (%0A) — отказ: grep -Eo по строкам вернул бы два «валидных» MAC
	case "$1" in *"
"*) return 0 ;; esac
	printf '%s' "$1" | tr 'A-F' 'a-f' | grep -Eo '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

# Список изолированных MAC (нижний регистр, через пробел) — для device_modes и awk.
iot_locked_macs() {
	[ -f "$IOT_LOCKDOWN_LIST" ] || return 0
	grep -vE '^[[:space:]]*#' "$IOT_LOCKDOWN_LIST" 2>/dev/null | tr 'A-F' 'a-f' | tr -d ' \t\r' | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

# IPv4 или IPv4/CIDR — защищает от инъекции произвольной строки в kvas.conf.
valid_ip_or_cidr() {
	_vic_pfx=""
	case "$1" in
		*/*) _vic_ip=${1%%/*}; _vic_pfx=${1#*/} ;;
		*)   _vic_ip=$1 ;;
	esac
	case "$_vic_ip" in ''|*[!0-9.]*) return 1 ;; esac
	# Без END{exit 0}: в awk `exit N` выполняет END-блок, который перезатёр бы код.
	printf '%s\n' "$_vic_ip" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++){ if($i=="" || $i ~ /[^0-9]/ || $i+0>255) exit 1 }}' || return 1
	if [ -n "$_vic_pfx" ]; then
		case "$_vic_pfx" in ''|*[!0-9]*) return 1 ;; esac
		[ "$_vic_pfx" -le 32 ] || return 1
	fi
	return 0
}

# Имя интерфейса/сегмента (buk, sstp0, oc0, …) — только безопасный набор символов.
valid_ifname() {
	case "$1" in ''|*[!A-Za-z0-9_.+-]*) return 1 ;; esac
	return 0
}

# Потомки процесса по /proc/<pid>/stat (поле 4 — PPID); pgrep -P есть не везде.
kill_descendants() {
	local c
	for c in $(awk -v p="$1" '$4 == p { print $1 }' /proc/[0-9]*/stat 2>/dev/null); do
		kill_descendants "$c"
		kill "$c" 2>/dev/null || true
	done
}

# Kill only the checker that KVAS started.  The cmdline guard prevents a stale
# PID file from ever signalling an unrelated router process.
stop_bypass_check() {
	local pid
	pid=$(cat "$BYPASS_CHECK_PID" 2>/dev/null)
	case "$pid" in
		''|*[!0-9]*) return 0 ;;
	esac
	if [ -r "/proc/$pid/cmdline" ] && tr '\000' ' ' < "/proc/$pid/cmdline" | grep -q '[b]ypass_check.sh'; then
		kill "$pid" 2>/dev/null || true
		# ash выполняет ловушку TERM только после текущей команды, а это curl
		# с таймаутом до 8 с — гасим и потомков ($(...)-подоболочки, curl).
		kill_descendants "$pid"
		for _ in 1 2 3; do
			kill -0 "$pid" 2>/dev/null || break
			sleep 1
		done
	fi
}

bypass_check_running() {
	local pid
	pid=$(cat "$BYPASS_CHECK_PID" 2>/dev/null)
	case "$pid" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ -r "/proc/$pid/cmdline" ] && \
		tr '\000' ' ' < "/proc/$pid/cmdline" | grep -q '[b]ypass_check.sh' && \
		kill -0 "$pid" 2>/dev/null
}

clear_stale_bypass_check() {
	# A power-off, package upgrade, or an older checker can leave its atomic
	# lock behind.  Never let that stale directory make the UI report a scan
	# forever or prevent the next one from starting.
	bypass_check_running && return 1
	rm -f "$BYPASS_CHECK_PID" "$BYPASS_CHECK_LOCK"
	rmdir "$BYPASS_CHECK_LOCK_DIR" 2>/dev/null || true
	return 0
}

# Query values are URL-encoded by the WebUI.  Decode only after selecting a
# field, so an encoded ampersand cannot change the query structure.
url_decode() {
	# awk, а не printf %b: в dash %b не знает \x, а \c обрывает вывод.
	# %00 и управляющие символы (кроме \t \n \r) выбрасываются; битый % остаётся как есть.
	printf '%s' "$1" | LC_ALL=C awk '
		BEGIN { for (i = 0; i < 256; i++) hex[sprintf("%02x", i)] = i }
		{
			if (NR > 1) printf "\n"
			s = $0; gsub(/\+/, " ", s); out = ""
			while ((p = index(s, "%")) > 0) {
				out = out substr(s, 1, p - 1)
				h = tolower(substr(s, p + 1, 2))
				if (h in hex) {
					n = hex[h]
					if (n >= 32 || n == 9 || n == 10 || n == 13) out = out sprintf("%c", n)
					s = substr(s, p + 3)
				} else {
					out = out "%"; s = substr(s, p + 1)
				}
			}
			printf "%s", out s
		}'
}

query_param() {
	local key="$1" raw
	raw=$(printf '%s\n' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -1)
	url_decode "$raw"
}

password_hash() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
password_hash_legacy() { printf '%s' "$1" | md5sum | awk '{print $1}'; }

write_password_hash() {
	local hash="$1" tmp
	mkdir -p "$(dirname "$PASS_FILE")" 2>/dev/null
	tmp="${PASS_FILE}.$$"
	( umask 077; printf 'sha256:%s\n' "$hash" > "$tmp" ) || return 1
	chmod 600 "$tmp" 2>/dev/null
	mv -f "$tmp" "$PASS_FILE"
}

# 0 = correct, 1 = incorrect.  A successful legacy MD5 login is migrated to
# SHA-256 immediately, so existing installations keep working.
verify_password() {
	local pass="$1" stored expected
	stored=$(cat "$PASS_FILE" 2>/dev/null | awk 'NR==1 {print $1}')
	case "$stored" in
		sha256:*)
			expected=${stored#sha256:}
			[ "$(password_hash "$pass")" = "$expected" ]
			;;
		?*)
			[ "$(password_hash_legacy "$pass")" = "$stored" ] || return 1
			write_password_hash "$(password_hash "$pass")"
			;;
		*) return 1 ;;
	esac
}

# Brute-force protection.
# Счётчики: по адресу клиента (SOCAT_PEERADDR от socat) и общий. Раньше был только
# общий — любой хост LAN 5 ошибками блокировал вход владельцу. Общий потолок выше,
# чтобы перебор со сменой IP всё равно упирался в лимит.
# Проверка → проверка пароля → запись ошибки идут под одним локом (auth_lock):
# иначе параллельные запросы все читали счётчик < MAX_FAILS и лимита не было.
FAIL_COUNT=/tmp/kvas_fail_count
FAIL_TIME=/tmp/kvas_fail_time
AUTH_LOCK_DIR=/tmp/kvas_auth.lock
MAX_FAILS=5
MAX_FAILS_TOTAL=30
LOCKOUT=300

peer_id() {
	case "$SOCAT_PEERADDR" in
		''|*[!0-9.]*) echo unknown ;;
		*) echo "$SOCAT_PEERADDR" ;;
	esac
}

# Блокировка по паре файлов счётчика: печатает остаток секунд и возвращает 1.
# Ошибки старше LOCKOUT забываются (окно), а не копятся бесконечно.
lockout_wait() {
	local count_file="$1" time_file="$2" max="$3" fails last now elapsed
	fails=$(cat "$count_file" 2>/dev/null)
	[ -n "$fails" ] || return 0
	last=$(cat "$time_file" 2>/dev/null || echo 0)
	now=$(date +%s 2>/dev/null || echo 0)
	elapsed=$((now - last))
	if [ "$elapsed" -ge "$LOCKOUT" ]; then
		rm -f "$count_file" "$time_file"
		return 0
	fi
	[ "$fails" -lt "$max" ] 2>/dev/null && return 0
	echo $((LOCKOUT - elapsed))
	return 1
}

check_bruteforce() {
	local peer
	peer=$(peer_id)
	lockout_wait "$FAIL_COUNT.$peer" "$FAIL_TIME.$peer" "$MAX_FAILS" || return 1
	lockout_wait "$FAIL_COUNT" "$FAIL_TIME" "$MAX_FAILS_TOTAL"
}

bump_fail() {
	local now fails
	now=$(date +%s 2>/dev/null || echo 0)
	fails=$(cat "$1" 2>/dev/null || echo 0)
	echo $((fails + 1)) > "$1"
	echo "$now" > "$2"
}

record_fail() {
	local peer
	peer=$(peer_id)
	bump_fail "$FAIL_COUNT.$peer" "$FAIL_TIME.$peer"
	bump_fail "$FAIL_COUNT" "$FAIL_TIME"
}

reset_fails() {
	local peer
	peer=$(peer_id)
	rm -f "$FAIL_COUNT.$peer" "$FAIL_TIME.$peer"
}

# Сериализация попыток входа (flock в busybox роутера нет — mkdir-лок).
# Владелец держит лок ~1-2 с; брошенным (CGI убит) считаем лок старше 30 с — по
# возрасту самого лока, а не по времени ожидания: иначе при очереди запросов
# ждущие сносили бы живой лок. Снос — атомарным mv, его выполнит только один.
auth_lock() {
	local born
	while ! mkdir "$AUTH_LOCK_DIR" 2>/dev/null; do
		born=$(date -r "$AUTH_LOCK_DIR" +%s 2>/dev/null) || continue
		if [ $(( $(date +%s) - born )) -gt 30 ] &&
			mv "$AUTH_LOCK_DIR" "$AUTH_LOCK_DIR.stale.$$" 2>/dev/null; then
			rm -rf "$AUTH_LOCK_DIR.stale.$$"
			continue
		fi
		sleep 1
	done
	trap 'auth_unlock' EXIT HUP INT TERM
}

auth_unlock() { rmdir "$AUTH_LOCK_DIR" 2>/dev/null; trap - EXIT HUP INT TERM; }



check_token() {
	local t="$1"
	[ -z "$t" ] && json_error "auth required"
	# Только формат mk_token: иначе ../<файл со свежим epoch> проходил как токен
	case "$t" in *[!0-9a-f]*) json_error "auth required" ;; esac
	[ ${#t} -eq 32 ] || json_error "auth required"
	[ ! -f "$TOKEN_DIR/$t" ] && json_error "invalid token"
	local created=$(cat "$TOKEN_DIR/$t" 2>/dev/null)
	[ -z "$created" ] && json_error "token expired"
	local now=$(date +%s 2>/dev/null || echo 0)
	[ $((now - created)) -gt 3600 ] && rm -f "$TOKEN_DIR/$t" && json_error "token expired"
	echo "$now" > "$TOKEN_DIR/$t"
}

mk_token() {
	mkdir -p "$TOKEN_DIR" 2>/dev/null
	local t=$(head -c 32 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')
	[ -z "$t" ] && t=$(echo "$$$(date)$$" | md5sum | awk '{print $1}')
	date +%s 2>/dev/null > "$TOKEN_DIR/$t" || echo "1" > "$TOKEN_DIR/$t"
	printf '%s' "$t"
}

# --- Main ---


check_service() {
	local service="$1"
	if [ -f "/opt/etc/init.d/${service}" ]; then
		/opt/etc/init.d/${service} status 2>/dev/null | grep -qi "alive\|running\|started" && echo "running" || echo "stopped"
	else
		echo "not_installed"
	fi
}

check_updates() {
	local current_ver=$(opkg list-installed 2>/dev/null | grep kvas | awk '{print $3}')
	local repo="shamanWeb/kvasec"
	# Новый формат: kvasec_1.2.0.ipk. Старый kvas_..._all.ipk здесь намеренно
	# не предлагается как обновление нового пакета.
	local latest_ver=$(curl -s --connect-timeout 5 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | \
		grep -o 'kvasec_[0-9]\+\.[0-9]\+\.[0-9]\+\.ipk' | head -1 | \
		sed 's/^kvasec_//; s/\.ipk$//')
	if [ -n "$latest_ver" ]; then
		local current_key=$(echo "$current_ver" | awk -F. '/^[0-9]+\.[0-9]+\.[0-9]+$/ {printf "%d%03d%03d", $1, $2, $3}')
		local latest_key=$(echo "$latest_ver" | awk -F. '/^[0-9]+\.[0-9]+\.[0-9]+$/ {printf "%d%03d%03d", $1, $2, $3}')
		if [ -n "$latest_key" ] && { [ -z "$current_key" ] || [ "$latest_key" -gt "$current_key" ]; }; then
			echo "available:v${latest_ver}"
		else
			echo "up_to_date"
		fi
	else
		echo "up_to_date"
	fi
}

# --- kvas.conf: списки IP/интерфейсов ---
# Раньше: grep → sed -i "/^key=/d" → echo >> без лока. Два быстрых клика теряли
# изменение, а параллельный `route refresh` мог увидеть файл без ключа.
# Лок — mkdir (flock в busybox роутера нет); брошенный — по возрасту самого лока.
conf_lock() {
	local born
	while ! mkdir "$CONF_LOCK_DIR" 2>/dev/null; do
		born=$(date -r "$CONF_LOCK_DIR" +%s 2>/dev/null) || continue
		if [ $(( $(date +%s) - born )) -gt 60 ] &&
			mv "$CONF_LOCK_DIR" "$CONF_LOCK_DIR.stale.$$" 2>/dev/null; then
			rm -rf "$CONF_LOCK_DIR.stale.$$"
			continue
		fi
		sleep 1
	done
}
conf_unlock() { rmdir "$CONF_LOCK_DIR" 2>/dev/null; }

# $1 ключ, $2 разделитель, $3 add|del, $4 элемент (точное сравнение).
# 0 — файл изменён, 1 — изменений не потребовалось, 2 — ошибка записи.
conf_list_edit() {
	local key="$1" sep="$2" op="$3" item="$4" tmp rc
	conf_lock
	[ -f "$KVAS_CONF_FILE" ] || : > "$KVAS_CONF_FILE"
	tmp="${KVAS_CONF_FILE}.tmp.$$"
	awk -v k="$key" -v s="$sep" -v op="$op" -v it="$item" '
		index($0, k "=") == 1 {
			if (found) { changed = 1; next }    # дубли ключа схлопываем
			found = 1
			n = split(substr($0, length(k) + 2), a, s); out = ""; has = 0
			for (i = 1; i <= n; i++) {
				if (a[i] == "") continue
				if (a[i] == it) { has = 1; if (op == "del") { changed = 1; continue } }
				out = out (out == "" ? "" : s) a[i]
			}
			if (op == "add" && !has) { out = out (out == "" ? "" : s) it; changed = 1 }
			if (out != "") print k "=" out
			next
		}
		{ print }
		END {
			if (!found && op == "add") { print k "=" it; changed = 1 }
			exit (changed ? 0 : 1)
		}' "$KVAS_CONF_FILE" > "$tmp"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		mv -f "$tmp" "$KVAS_CONF_FILE" || rc=2
	else
		rm -f "$tmp"
	fi
	conf_unlock
	return "$rc"
}

main() {
	local action token pass hash stored kvaspkg kvaspkg_name kvaspkg_ver
	local host_count first
	local domain out rc mode path

	action=$(query_param action)
	token=$(query_param token)
	[ -z "$token" ] && token="$HTTP_X_KVAS_TOKEN"

	case "$action" in
		auth_status)
			if [ -f "$PASS_FILE" ] && [ -s "$PASS_FILE" ]; then
				printf '{"ok":true,"has_password":true}\n'
			else
				printf '{"ok":true,"has_password":false}\n'
			fi
			;;
		set_pass)
			[ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"
			[ -s "$PASS_FILE" ] && json_error "password already set; authenticate to change it"
			pass=$(query_param pass); [ -z "$pass" ] && pass=$(url_decode "$HTTP_X_KVAS_PASS")
			[ -z "$pass" ] && json_error "pass required"
			[ ${#pass} -lt 8 ] && json_error "min 8 symbols"
			write_password_hash "$(password_hash "$pass")" || json_error "cannot save password"
			json_ok "password set"
			;;
		auth)
			[ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"
			pass=$(query_param pass); [ -z "$pass" ] && pass=$(url_decode "$HTTP_X_KVAS_PASS")
			[ -z "$pass" ] && json_error "pass required"
			auth_lock
			wait=$(check_bruteforce); check_rc=$?
			if [ "$check_rc" -ne 0 ]; then
				auth_unlock
				printf '{"error":"too many attempts","wait":%s}\n' "${wait:-300}"
				return
			fi
			if ! verify_password "$pass"; then
				record_fail
				# пауза под локом: не больше ~1 попытки в секунду со всех адресов
				sleep 1
				auth_unlock
				json_error "wrong password"
			fi
			reset_fails
			auth_unlock
			token=$(mk_token)
			printf '{"ok":true,"token":"%s"}\n' "$token"
			;;
		change_pass)
			check_token "$token"
			[ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"
			current=$(query_param current); [ -z "$current" ] && current=$(url_decode "$HTTP_X_KVAS_CURRENT")
			new_pass=$(query_param new_pass); [ -z "$new_pass" ] && new_pass=$(url_decode "$HTTP_X_KVAS_NEW_PASS")
			[ -n "$current" ] && [ -n "$new_pass" ] || json_error "current and new password required"
			[ ${#new_pass} -lt 8 ] && json_error "min 8 symbols"
			verify_password "$current" || json_error "wrong current password"
			write_password_hash "$(password_hash "$new_pass")" || json_error "cannot save password"
			json_ok "password changed"
			;;
		system_status)
			check_token "$token"
			kvaspkg=$(opkg list-installed 2>/dev/null | grep kvas | head -1)
			kvaspkg_name=$(echo "$kvaspkg" | awk '{print $1}')
			kvaspkg_ver=$(echo "$kvaspkg" | awk '{print $3}')
			host_count=$(wc -l < "$KVAS_LIST" 2>/dev/null || echo 0)
			printf '{"ok":true,"pkg":%s,"ver":%s,"mode":"amneziawg","hosts":%s}\n' \
				"$(json_str "$kvaspkg_name")" "$(json_str "$kvaspkg_ver")" "$host_count"
			;;
		hosts)
			check_token "$token"
			[ ! -f "$KVAS_LIST" ] && echo '{"ok":true,"hosts":[]}' && return
			printf '{"ok":true,"hosts":['
			first=1
			while IFS= read -r line; do
				[ -z "$line" ] && continue
				[ "$first" -eq 0 ] && printf ','
				first=0
				printf '%s' "$(json_str "$line")"
			done < "$KVAS_LIST"
			echo ']}'
			;;
		host_add)
			check_token "$token"
			domain=$(echo "$QUERY_STRING" | sed 's/.*domain=//; s/&.*//' 2>/dev/null)
			[ "$domain" = "$QUERY_STRING" ] && domain=""
			[ -z "$domain" ] && json_error "domain required"
			# Wildcard: *.example.com or *example.com → store *.example.com in kvas.list
			wildcard=false
			case "$domain" in
				\**) wildcard=true; clean=$(echo "$domain" | sed 's/^\*\.*//');;
				*)   clean="$domain";;
			esac
			# Валидируем очищенный домен ДО использования в sed/kvas: отсекает
			# спецсимволы sed (|, &, / …) и прочую инъекцию в kvas.list.
			clean=$(printf '%s' "$clean" | tr 'A-Z' 'a-z')
			valid_domain "$clean" || json_error "invalid domain"
			out=$($KVAS_BIN add "$clean" 2>&1)
			rc=$?
			[ $rc -ne 0 ] && json_error "add failed: $out"
			if $wildcard; then
				# kvas add wrote clean entry; rename it to *.clean in kvas.list
				sed -i "s|^${clean}$|*.${clean}|" "$KVAS_LIST" 2>/dev/null
				json_ok "added *.${clean}"
			else
				json_ok "added $domain"
			fi
			;;
		host_del)
			check_token "$token"
			domain=$(query_param domain)
			[ -z "$domain" ] && json_error "domain required"
			# Strip wildcard prefix: *.example.com → example.com for kvas del
			clean=$(printf '%s' "$domain" | sed 's/^\*\.*//')
			# Только набор символов: удаляем то, что реально лежит в kvas.list (там бывают
			# *.ru, _dmarc.x, заглавные — строгий valid_domain их отвергал). kvas del
			# сравнивает точно, инъекции нет; ведущий '-' — запрет option injection.
			case "$clean" in ''|-*|*[!A-Za-z0-9._/*-]*) json_error "invalid domain" ;; esac
			case "$clean" in *[A-Za-z0-9]*) ;; *) json_error "invalid domain" ;; esac
			out=$($KVAS_BIN del "$clean" 2>&1)
			rc=$?
			[ $rc -ne 0 ] && json_error "del failed: $out"
			# Rebuild ipset and restart services
			$KVAS_BIN init >/dev/null 2>&1
			json_ok "removed $domain (ipset updated)"
			;;
		host_import)
			check_token "$token"
			# ровно Content-Length байт: `cat` ждал EOF, которого браузер не шлёт
			domains=""
			[ "${CONTENT_LENGTH:-0}" -gt 0 ] 2>/dev/null && domains=$(head -c "$CONTENT_LENGTH" 2>/dev/null)
			if [ -z "$domains" ]; then
				domains=$(echo "$QUERY_STRING" | sed 's/.*domains=//; s/&.*//' 2>/dev/null | sed 's/%0A/
/g; s/+/ /g')
			fi
			[ -z "$domains" ] && json_error "domains required"
			total=$(echo "$domains" | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*#' | grep '\.' | wc -l)
			[ "$total" = "0" ] && json_error "нет доменов для импорта"
			[ -f /tmp/kvas_import_pid.txt ] && kill "$(cat /tmp/kvas_import_pid.txt)" 2>/dev/null
			rm -f /tmp/kvas_import_out.txt /tmp/kvas_import_data.txt /tmp/kvas_import_pid.txt
			echo "$domains" > /tmp/kvas_import_data.txt
			(
				$KVAS_BIN import /tmp/kvas_import_data.txt > /tmp/kvas_import_out.txt 2>&1
				echo ">>>EXIT:$?" >> /tmp/kvas_import_out.txt
			) < /dev/null &
			echo $! > /tmp/kvas_import_pid.txt
			printf '{"ok":true,"total":%s}\n' "$total"
			;;
		host_import_poll)
			check_token "$token"
			if [ ! -f /tmp/kvas_import_out.txt ]; then
				printf '{"ok":true,"done":true,"running":false}\n'
				return
			fi
			if grep -q ">>>EXIT:" /tmp/kvas_import_out.txt 2>/dev/null; then
				import_out=$(grep -v ">>>EXIT:" /tmp/kvas_import_out.txt 2>/dev/null)
				exit_code=$(grep ">>>EXIT:" /tmp/kvas_import_out.txt 2>/dev/null | sed 's/>>>EXIT://')
				rm -f /tmp/kvas_import_out.txt /tmp/kvas_import_data.txt /tmp/kvas_import_pid.txt
				[ "$exit_code" != "0" ] && printf '{"ok":false,"error":"import failed","output":%s}\n' "$(json_str "$import_out")" && return
				printf '{"ok":true,"done":true,"output":%s}\n' "$(json_str "$import_out")"
			else
				lines=$(wc -l < /tmp/kvas_import_out.txt 2>/dev/null || echo 0)
				last_line=$(tail -1 /tmp/kvas_import_out.txt 2>/dev/null || echo "")
				printf '{"ok":true,"done":false,"lines":%s,"last":%s}\n' "$lines" "$(json_str "$last_line")"
			fi
			;;
		host_clear)
			check_token "$token"
			: > "$KVAS_LIST"
			out=$($KVAS_BIN init 2>&1)
			json_ok "list cleared"
			;;
		update)
			check_token "$token"
			out=$($KVAS_BIN update 2>&1; $KVAS_BIN init 2>&1)
			rc=$?
			[ $rc -ne 0 ] && json_error "update failed: $out"
			json_ok "update done"
			;;
		kvas_init)
			check_token "$token"
			out=$($KVAS_BIN init 2>&1)
			rc=$?
			[ $rc -ne 0 ] && json_error "init failed: $out"
			json_ok "kvas init done"
			;;
		upgrade)
			check_token "$token"
			[ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"
			# Package postinst restarts this WebUI. Return before starting the
			# updater, otherwise the browser loses its request with the old listener.
			# код выхода — в конец лога (kvas upgrade теперь возвращает честный код)
			( sleep 1; "$KVAS_BIN" upgrade > "$UPGRADE_LOG" 2>&1; echo ">>>EXIT:$?" >> "$UPGRADE_LOG" ) &
			json_ok "upgrade started; WebUI will restart shortly"
			;;
		check_update)
			check_token "$token"
			update_info=$(check_updates 2>/dev/null)
			printf '{"ok":true,"update":%s}\n' "$(json_str "$update_info")"
			;;
		bypass_check_start)
			check_token "$token"
			[ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"
			mode=$(query_param mode)
			case "$mode" in all|dns|mixed|domain|'') ;; *) json_error "invalid check mode";; esac
			[ -z "$mode" ] && mode=mixed
			domain=""
			if [ "$mode" = domain ]; then
				domain=$(query_param domain | tr '[:upper:]' '[:lower:]')
				printf '%s\n' "$domain" | grep -Eq '^[a-z0-9][a-z0-9.-]*\.[a-z0-9.-]*[a-z0-9]$' || json_error "invalid domain"
				case "$domain" in *..*) json_error "invalid domain";; esac
			fi
			clear_stale_bypass_check || json_error "check already running"
			# mkdir is atomic on the router filesystem, unlike check-then-create
			# of a regular file.  It prevents concurrent expensive scans.
			if ! mkdir "$BYPASS_CHECK_LOCK_DIR" 2>/dev/null; then
				json_error "check already running"
			fi
			if [ ! -x "$BYPASS_CHECK_BIN" ]; then rmdir "$BYPASS_CHECK_LOCK_DIR" 2>/dev/null; json_error "bypass checker is not installed"; fi
			rm -f "$BYPASS_CHECK_RESULT"
			rm -f "$BYPASS_CHECK_PROGRESS"
			BYPASS_LOCK_DIR="$BYPASS_CHECK_LOCK_DIR" BYPASS_PID_FILE="$BYPASS_CHECK_PID" BYPASS_MODE="$mode" BYPASS_DOMAIN="$domain" "$BYPASS_CHECK_BIN" > "$BYPASS_CHECK_LOG" 2>&1 &
			printf '%s\n' "$!" > "$BYPASS_CHECK_PID"
			json_ok "bypass check started"
			;;
		bypass_check_stop)
			check_token "$token"
			[ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"
			stop_bypass_check
			rm -f "$BYPASS_CHECK_PID" "$BYPASS_CHECK_LOCK" "$BYPASS_CHECK_PROGRESS" "$BYPASS_CHECK_RESULT"
			rmdir "$BYPASS_CHECK_LOCK_DIR" 2>/dev/null || true
			json_ok "bypass check stopped"
			;;
		bypass_check_status)
			check_token "$token"
			if bypass_check_running; then
				progress_done=0; progress_total=0
				if [ -f "$BYPASS_CHECK_PROGRESS" ]; then
					IFS='|' read -r progress_done progress_total < "$BYPASS_CHECK_PROGRESS"
					case "$progress_done" in ''|*[!0-9]*) progress_done=0;; esac
					case "$progress_total" in ''|*[!0-9]*) progress_total=0;; esac
				fi
				printf '{"ok":true,"running":true,"done":%s,"total":%s,"checked":[]}\n' "${progress_done:-0}" "${progress_total:-0}"
				return
			fi
			clear_stale_bypass_check
			if [ -s "$BYPASS_CHECK_RESULT" ]; then
				cat "$BYPASS_CHECK_RESULT"
			else
				echo '{"ok":true,"running":false,"checked":[]}'
			fi
			;;
		tunnel_dpi)
			# Индикатор DPI-интерференции (РКН/ТСПУ) на не-NDM AWG-туннеле.
			# RX drops на opkgtunNN = пакеты, испорченные/отброшенные на пути —
			# прямой след DPI (в отличие от awg0 сервера, где на входе всегда 0).
			check_token "$token"
			iface=$(sed -n 's/^INFACE_ENT=//p' /opt/etc/kvas.conf 2>/dev/null | tr -d ' \r')
			[ -z "$iface" ] && iface=opkgtun10
			stat="/sys/class/net/$iface/statistics"
			if [ ! -d "$stat" ]; then
				echo '{"ok":true,"up":false}'
				return
			fi
			rx_drop=$(cat "$stat/rx_dropped" 2>/dev/null || echo 0)
			rx_pkts=$(cat "$stat/rx_packets" 2>/dev/null || echo 0)
			now=$(date +%s)
			prev_file=/tmp/kvas_dpi_prev
			rate=0; loss_pct=0
			if [ -f "$prev_file" ]; then
				read -r p_drop p_pkts p_time < "$prev_file"
				# защита от битого/частично записанного prev (busybox падает на пустой арифметике)
				if echo "$p_drop $p_pkts $p_time" | grep -qE '^[0-9]+ [0-9]+ [0-9]+$'; then
					dt=$((now - p_time)); dd=$((rx_drop - p_drop)); dp=$((rx_pkts - p_pkts))
					if [ "$dd" -lt 0 ]; then
						rate=0; loss_pct=0   # счётчик сбросился (реконнект туннеля)
					else
						[ "$dt" -gt 0 ] && rate=$(( dd * 60 / dt ))
						[ $((dp + dd)) -gt 0 ] && loss_pct=$(( dd * 100 / (dp + dd) ))
					fi
				fi
			fi
			echo "$rx_drop $rx_pkts $now" > "$prev_file"
			hs=$(awg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
			hs_age=-1
			[ -n "$hs" ] && [ "$hs" -gt 0 ] 2>/dev/null && hs_age=$((now - hs))
			printf '{"ok":true,"up":true,"drops_total":%s,"drops_per_min":%s,"loss_pct":%s,"handshake_age":%s}\n' \
				"${rx_drop:-0}" "${rate:-0}" "${loss_pct:-0}" "${hs_age:--1}"
			;;
		dpi_history)
			# История DPI-интерференции для графика (собирается cron-скриптом
			# dpi_history.sh раз в минуту, кольцевой буфер 1440 точек = 24ч).
			check_token "$token"
			if [ -s /tmp/dpi-history.jsonl ]; then
				printf '{"ok":true,"points":['
				awk 'NR>1{printf ","} {printf "%s",$0}' /tmp/dpi-history.jsonl
				printf ']}\n'
			else
				echo '{"ok":true,"points":[]}'
			fi
			;;
		backup)
			check_token "$token"
			out=$($KVAS_BIN backup 2>&1)
			rc=$?
			[ $rc -ne 0 ] && json_error "backup failed: $out"
			json_ok "backup done: $out"
			;;
		restore)
			check_token "$token"
			path=$(query_param path)
			# restore перезаписывает kvas.conf/dnsmasq.conf и пароль панели — только
			# каталоги, созданные `kvas backup` (UI путь не передаёт: берётся последний)
			if [ -n "$path" ]; then
				echo "$path" | grep -Eqx '/opt/kvas_backup_[0-9]{8}-[0-9]{6}' && [ "$(printf '%s' "$path" | wc -l)" -eq 0 ] \
					|| json_error "invalid backup path"
			fi
			out=$($KVAS_BIN restore "$path" 2>&1)
			rc=$?
			[ $rc -ne 0 ] && json_error "restore failed: $out"
			json_ok "restore done"
			;;
		parental_list)
			check_token "$token"
			if [ ! -f "$PARENTAL_LIST" ]; then
				echo '{"ok":true,"sites":[]}'
				return
			fi
			printf '{"ok":true,"sites":['
			first=1
			while IFS= read -r line; do
				[ -z "$line" ] && continue
				[ "${line:0:1}" = "#" ] && continue
				[ "$first" -eq 0 ] && printf ','
				first=0
				printf '%s' "$(json_str "$line")"
			done < "$PARENTAL_LIST"
			echo ']}'
			;;
		parental_add)
			check_token "$token"
			domain=$(echo "$QUERY_STRING" | sed 's/.*domain=//; s/&.*//' 2>/dev/null)
			[ "$domain" = "$QUERY_STRING" ] && domain=""
			domain=$(normalize_domain "$domain")
			valid_domain "$domain" || json_error "valid domain required"
			adguard_active && json_error "Родительский контроль через dnsmasq недоступен, пока активен AdGuard Home"
			# Автоматически включаем adblock, если выключен
			if ! grep -q "addn-hosts=/opt/etc/adblock/ads.kvas.list" /opt/etc/dnsmasq.conf 2>/dev/null; then
				echo "addn-hosts=/opt/etc/adblock/ads.kvas.list" >> /opt/etc/dnsmasq.conf
				[ -f /opt/etc/adblock/ads.kvas.list ] || sh /opt/apps/kvas/bin/main/adblock >/dev/null 2>&1
				/opt/etc/init.d/S56dnsmasq restart >/dev/null 2>&1
			fi
			out=$($KVAS_BIN adblock add "$domain" 2>&1)
			rc=$?
			[ $rc -ne 0 ] && json_error "block failed: $out"
			json_ok "blocked $domain"
			;;
		parental_del)
			check_token "$token"
			domain=$(echo "$QUERY_STRING" | sed 's/.*domain=//; s/&.*//' 2>/dev/null)
			[ "$domain" = "$QUERY_STRING" ] && domain=""
			domain=$(normalize_domain "$domain")
			valid_domain "$domain" || json_error "valid domain required"
			adguard_active && json_error "Родительский контроль через dnsmasq недоступен, пока активен AdGuard Home"
			out=$($KVAS_BIN adblock del "$domain" 2>&1)
			rc=$?
			[ $rc -ne 0 ] && json_error "unblock failed: $out"
			json_ok "unblocked $domain"
			;;
		adblock_status)
			check_token "$token"
			ads_count=0
			[ -f /opt/etc/adblock/ads.kvas.list ] && ads_count=$(wc -l < /opt/etc/adblock/ads.kvas.list 2>/dev/null | tr -d ' ')
			if adguard_active; then
				echo '{"ok":true,"adblock":"unavailable"}'
			elif grep -q "addn-hosts=/opt/etc/adblock/ads.kvas.list" /opt/etc/dnsmasq.conf 2>/dev/null; then
				printf '{"ok":true,"adblock":"on","count":%s}\n' "${ads_count:-0}"
			else
				printf '{"ok":true,"adblock":"off","count":%s}\n' "${ads_count:-0}"
			fi
			;;
		adblock_update)
			check_token "$token"
			adguard_active && json_error "Adblock через dnsmasq недоступен, пока активен AdGuard Home"
			[ -f /tmp/kvas_adblock_pid.txt ] && kill "$(cat /tmp/kvas_adblock_pid.txt)" 2>/dev/null
			rm -f /tmp/kvas_adblock_out.txt /tmp/kvas_adblock_pid.txt
			(
				sh /opt/apps/kvas/bin/main/adblock yes > /tmp/kvas_adblock_out.txt 2>&1
				echo ">>>EXIT:$?" >> /tmp/kvas_adblock_out.txt
			) < /dev/null &
			echo $! > /tmp/kvas_adblock_pid.txt
			echo '{"ok":true}'
			;;
		adblock_update_poll)
			check_token "$token"
			if [ ! -f /tmp/kvas_adblock_out.txt ]; then
				printf '{"ok":true,"done":true,"running":false}\n'
				return
			fi
			# adblock красит вывод ANSI-кодами и \r — чистим, иначе в UI виден мусор
			ansi_strip="s/$(printf '\033')\[[0-9;]*m//g; s/$(printf '\r')//g"
			if grep -q ">>>EXIT:" /tmp/kvas_adblock_out.txt 2>/dev/null; then
				ab_out=$(grep -v ">>>EXIT:" /tmp/kvas_adblock_out.txt 2>/dev/null | tail -8 | sed "$ansi_strip")
				ab_exit=$(grep ">>>EXIT:" /tmp/kvas_adblock_out.txt 2>/dev/null | sed 's/>>>EXIT://')
				ab_count=0
				[ -f /opt/etc/adblock/ads.kvas.list ] && ab_count=$(wc -l < /opt/etc/adblock/ads.kvas.list 2>/dev/null | tr -d ' ')
				rm -f /tmp/kvas_adblock_out.txt /tmp/kvas_adblock_pid.txt
				[ "$ab_exit" != "0" ] && printf '{"ok":false,"error":"update failed","output":%s}\n' "$(json_str "$ab_out")" && return
				printf '{"ok":true,"done":true,"count":%s,"output":%s}\n' "${ab_count:-0}" "$(json_str "$ab_out")"
			else
				ab_last=$(tail -1 /tmp/kvas_adblock_out.txt 2>/dev/null | sed "$ansi_strip" || echo "")
				printf '{"ok":true,"done":false,"last":%s}\n' "$(json_str "$ab_last")"
			fi
			;;
		adguard_status)
			check_token "$token"
			adguard_status_json
			;;
		adguard_on)
			check_token "$token"
			if adguard_active; then
				json_ok "AdGuard Home уже включен"
			fi
			if adguard_setup_running; then
				json_ok "Настройка AdGuard Home уже выполняется"
			fi
			adguard_web_backup || json_error "Не удалось сохранить состояние DNS перед переключением"
			: > "$ADGUARD_WEB_LOG"
			/opt/sbin/start-stop-daemon -S -b -m -p "$ADGUARD_WEB_PID" -O "$ADGUARD_WEB_LOG" -x "$KVAS_BIN" -- adguard on web || \
				json_error "Не удалось запустить настройку AdGuard Home в фоне"
			json_ok "Состояние DNS сохранено. Запущена настройка AdGuard Home. Если это первая установка, откройте http://192.168.1.1:3000 и завершите мастер настройки. Кнопка «Вернуть dnsmasq» отменит настройку и восстановит сохранённое состояние."
			;;
		adguard_off)
			check_token "$token"
			[ -d "$ADGUARD_WEB_BACKUP" ] || json_error "Нет сохранённого состояния DNS: AdGuard был включён не через Web UI"
			adguard_web_restore > "$ADGUARD_WEB_LOG" 2>&1 || json_error "Не удалось восстановить сохранённое состояние DNS"
			adguard_active && json_error "AdGuard Home всё ещё запущен"
			[ -x /opt/etc/init.d/S56dnsmasq ] && /opt/etc/init.d/S56dnsmasq status 2>/dev/null | grep -q alive || json_error "AdGuard остановлен, но dnsmasq не запустился"
			json_ok "Восстановлены dnsmasq, dnscrypt и маршрутизация KVASEC"
			;;
		adblock_on)
			check_token "$token"
			adguard_active && json_error "Adblock через dnsmasq недоступен, пока активен AdGuard Home"
			if ! grep -q "addn-hosts=/opt/etc/adblock/ads.kvas.list" /opt/etc/dnsmasq.conf 2>/dev/null; then
				echo "addn-hosts=/opt/etc/adblock/ads.kvas.list" >> /opt/etc/dnsmasq.conf
			fi
			[ -f /opt/etc/adblock/ads.kvas.list ] || sh /opt/apps/kvas/bin/main/adblock >/dev/null 2>&1
			/opt/apps/kvas/bin/main/parental_dns >/dev/null 2>&1
			/opt/etc/init.d/S56dnsmasq restart >/dev/null 2>&1
			echo '{"ok":true,"msg":"Adblock включен"}'
			;;
		adblock_off)
			check_token "$token"
			adguard_active && json_error "Adblock через dnsmasq недоступен, пока активен AdGuard Home"
			sed -i '/addn-hosts=\/opt\/etc\/adblock\/ads.kvas.list/d' /opt/etc/dnsmasq.conf 2>/dev/null
			/opt/etc/init.d/S56dnsmasq restart >/dev/null 2>&1
			echo '{"ok":true,"msg":"Adblock выключен"}'
			;;
		rotate_status)
			check_token "$token"
			if [ -f /opt/etc/kvas-rotate-enabled ]; then
				rint=$(cat /opt/etc/kvas-rotate-enabled 2>/dev/null)
				case "$rint" in ''|*[!0-9]*) rint=10 ;; esac
				rstate=on
			else
				rint=10; rstate=off
			fi
			rif=$(/opt/sbin/awg show interfaces 2>/dev/null | tr ' \t' '\n' | grep -m1 '^opkgtun')
			rport=$(/opt/sbin/awg show "$rif" 2>/dev/null | sed -n 's/.*listening port: //p' | tr -dc '0-9')
			printf '{"ok":true,"rotate":"%s","interval":%s,"port":"%s"}\n' "$rstate" "$rint" "$rport"
			;;
		rotate_on)
			check_token "$token"
			rint=$(query_param interval)
			case "$rint" in ''|*[!0-9]*) rint=10 ;; esac
			[ "$rint" -ge 1 ] 2>/dev/null || rint=10
			if "$KVAS_BIN" rotate on "$rint" >/dev/null 2>&1; then
				printf '{"ok":true,"msg":"Ротация включена (каждые %s мин)"}\n' "$rint"
			else
				json_error "не удалось включить ротацию"
			fi
			;;
		rotate_off)
			check_token "$token"
			if "$KVAS_BIN" rotate off >/dev/null 2>&1; then
				echo '{"ok":true,"msg":"Ротация выключена"}'
			else
				json_error "не удалось выключить ротацию"
			fi
			;;
		route_status)
			check_token "$token"
			route_full=$(grep "^route_full_ip=" "$KVAS_CONF_FILE" 2>/dev/null | cut -d= -f2 | tr '+' ' ')
			route_list=$(grep "^route_by_list_ip=" "$KVAS_CONF_FILE" 2>/dev/null | cut -d= -f2 | tr '+' ' ')
			route_exclude=$(grep "^route_excluded_ip=" "$KVAS_CONF_FILE" 2>/dev/null | cut -d= -f2 | tr '+' ' ')
			route_guest=$(grep "^INFACE_GUEST_ENT=" "$KVAS_CONF_FILE" 2>/dev/null | cut -d= -f2)
			# Get device names from DHCP for descriptions
			devs=$(curl -s "127.0.0.1:79/rci/show/ip/dhcp/bindings" 2>/dev/null | jq -r '.lease[] | "\(.ip)|\(.name)"' 2>/dev/null)
			_resolve_names() {
				local result=""
				for _ip in $1; do
					_name=$(echo "$devs" | grep -F "${_ip}|" | head -1 | cut -d'|' -f2)
					[ -n "$_name" ] && result="$result $_ip ($_name)" || result="$result $_ip"
				done
				echo "$result" | sed 's/^ //'
			}
			route_full=$(_resolve_names "$route_full")
			route_list=$(_resolve_names "$route_list")
			route_exclude=$(_resolve_names "$route_exclude")
			printf '{"ok":true,"full":%s,"list":%s,"exclude":%s,"guest_nets":%s}\n' \
				"$(json_str "$route_full")" "$(json_str "$route_list")" "$(json_str "$route_exclude")" "$(json_str "$route_guest")"
			;;
		route_list)
			check_token "$token"
			route_full=$(grep "^route_full_ip=" "$KVAS_CONF_FILE" 2>/dev/null | cut -d= -f2 | tr '+' ' ')
			route_list=$(grep "^route_by_list_ip=" "$KVAS_CONF_FILE" 2>/dev/null | cut -d= -f2 | tr '+' ' ')
			route_exclude=$(grep "^route_excluded_ip=" "$KVAS_CONF_FILE" 2>/dev/null | cut -d= -f2 | tr '+' ' ')
			printf '{"ok":true,"routes":['
			first=1
			for ip in $route_full; do
				[ -z "$ip" ] && continue
				[ "$first" -eq 0 ] && printf ','
				first=0
				printf '{"type":"full","ip":"%s"}' "$ip"
			done
			for ip in $route_list; do
				[ -z "$ip" ] && continue
				[ "$first" -eq 0 ] && printf ','
				first=0
				printf '{"type":"list","ip":"%s"}' "$ip"
			done
			for ip in $route_exclude; do
				[ -z "$ip" ] && continue
				[ "$first" -eq 0 ] && printf ','
				first=0
				printf '{"type":"exclude","ip":"%s"}' "$ip"
			done
			echo ']}'
			;;
		route_add)
			check_token "$token"
			type=$(echo "$QUERY_STRING" | sed 's/.*type=//; s/&.*//' 2>/dev/null)
			ip=$(echo "$QUERY_STRING" | sed 's/.*ip=//; s/&.*//; s/+/ /g; s/%2B/+/gi; s/%2F/\//gi; s/%20/ /g' 2>/dev/null)
			[ -z "$ip" ] && json_error "ip required"
			valid_ip_or_cidr "$ip" || json_error "invalid ip"
			case "$type" in
				full) key="route_full_ip" ;;
				list) key="route_by_list_ip" ;;
				exclude) key="route_excluded_ip" ;;
				*) json_error "type must be full, list, or exclude" ;;
			esac
			conf_list_edit "$key" + add "$ip"; rc=$?
			if [ "$rc" -eq 1 ]; then
				json_ok "already exists"
			elif [ "$rc" -ne 0 ]; then
				json_error "cannot write kvas.conf"
			else
				if $KVAS_BIN route refresh >> /tmp/kvas-route-refresh.log 2>&1; then
					json_ok "added $ip to $type"
				else
					json_error "route refresh failed, see /tmp/kvas-route-refresh.log"
				fi
			fi
			;;
		route_del)
			check_token "$token"
			type=$(echo "$QUERY_STRING" | sed 's/.*type=//; s/&.*//' 2>/dev/null)
			ip=$(echo "$QUERY_STRING" | sed 's/.*ip=//; s/&.*//; s/+/ /g; s/%2B/+/gi; s/%2F/\//gi; s/%20/ /g' 2>/dev/null)
			[ -z "$ip" ] && json_error "ip required"
			valid_ip_or_cidr "$ip" || json_error "invalid ip"
			case "$type" in
				full) key="route_full_ip" ;;
				list) key="route_by_list_ip" ;;
				exclude) key="route_excluded_ip" ;;
				*) json_error "type must be full, list, or exclude" ;;
			esac
			conf_list_edit "$key" + del "$ip"; rc=$?
			if [ "$rc" -eq 1 ]; then
				json_ok "not found"
			elif [ "$rc" -ne 0 ]; then
				json_error "cannot write kvas.conf"
			else
				if $KVAS_BIN route refresh >> /tmp/kvas-route-refresh.log 2>&1; then
					json_ok "removed $ip from $type"
				else
					json_error "route refresh failed, see /tmp/kvas-route-refresh.log"
				fi
			fi
			;;
		route_refresh)
			check_token "$token"
			out=$($KVAS_BIN route refresh 2>&1)
			json_ok "routes refreshed"
			;;
		route_devices)
			check_token "$token"
			_tmpdev="/tmp/kvas_route_devices.$$"
			: > "$_tmpdev"
			# DHCP bindings (приоритет — реальные имена)
			curl -s "127.0.0.1:79/rci/show/ip/dhcp/bindings" 2>/dev/null | \
				jq -r '.lease[] | "\(.ip)|\(.name)"' 2>/dev/null >> "$_tmpdev"
			# ARP-соседи (только IPv4)
			if command -v ip >/dev/null 2>&1; then
				ip neigh show 2>/dev/null | grep -E 'REACHABLE|STALE|DELAY' | \
					awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1 "|" ($5 ? $5 : "arp")}' >> "$_tmpdev"
			elif [ -f /proc/net/arp ]; then
				tail -n +2 /proc/net/arp 2>/dev/null | awk '$2 != "0x0" {print $1 "|arp"}' >> "$_tmpdev"
			fi
			# Активные IP из conntrack — только частные диапазоны (RFC 1918)
			_priv_re='src=(10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+)'
			if command -v conntrack >/dev/null 2>&1; then
				conntrack -L 2>/dev/null | grep -oE "$_priv_re" | cut -d= -f2 | sort -u | \
					awk '{print $1 "|conntrack"}' >> "$_tmpdev"
			elif [ -f /proc/net/nf_conntrack ]; then
				grep -oE "$_priv_re" /proc/net/nf_conntrack 2>/dev/null | cut -d= -f2 | sort -u | \
					awk '{print $1 "|conntrack"}' >> "$_tmpdev"
			fi
			unset _priv_re
			# Вывод с дедупликацией (оставляем первую запись — у DHCP приоритет)
			printf '{"ok":true,"devices":['
			awk -F'|' "$AWK_JESC"'!seen[$1]++{if(f++) printf ","; printf "{\"ip\":\"%s\",\"name\":\"%s\"}", jesc($1), jesc($2)}' "$_tmpdev" 2>/dev/null
			rm -f "$_tmpdev"
			echo ']}'
			;;
		device_modes)
			check_token "$token"
			route_full=$(grep "^route_full_ip=" "$KVAS_CONF_FILE" 2>/dev/null | cut -d= -f2)
			route_exclude=$(grep "^route_excluded_ip=" "$KVAS_CONF_FILE" 2>/dev/null | cut -d= -f2)
			_tmpdev="/tmp/kvas_dev_modes.$$"
			: > "$_tmpdev"
			# Keenetic hotspot — авторитетный источник: ip|name|mac|access (вкл. запрет интернета)
			# '|' в имени → пробел (split/join, т.к. jq на роутере без oniguruma → без gsub);
			# null mac/access → пусто/permit
			curl -s "127.0.0.1:79/rci/show/ip/hotspot" 2>/dev/null | \
				jq -r '.host[] | select(.ip != "" and .ip != null) | "\(.ip)|\((.name // "") | split("|") | join(" "))|\(.mac // "")|\(.access // "permit")"' 2>/dev/null >> "$_tmpdev"
			# DHCP bindings — статические аренды, не попавшие в hotspot (mac/access неизвестны)
			curl -s "127.0.0.1:79/rci/show/ip/dhcp/bindings" 2>/dev/null | \
				jq -r '.lease[] | "\(.ip)|\((.name // "") | split("|") | join(" "))||permit"' 2>/dev/null >> "$_tmpdev"
			# ARP-соседи (только IPv4) — с MAC, чтобы их тоже можно было блокировать
			if command -v ip >/dev/null 2>&1; then
				ip neigh show 2>/dev/null | grep -E 'REACHABLE|STALE|DELAY' | \
					awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1 "|arp|" ($5 ? $5 : "") "|permit"}' >> "$_tmpdev"
			elif [ -f /proc/net/arp ]; then
				tail -n +2 /proc/net/arp 2>/dev/null | awk '$2 != "0x0" {print $1 "|arp|" $4 "|permit"}' >> "$_tmpdev"
			fi
			# Активные IP из conntrack — только частные диапазоны (RFC 1918)
			_priv_re='src=(10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+)'
			if command -v conntrack >/dev/null 2>&1; then
				conntrack -L 2>/dev/null | grep -oE "$_priv_re" | cut -d= -f2 | sort -u | \
					awk '{print $1 "|conntrack||permit"}' >> "$_tmpdev"
			elif [ -f /proc/net/nf_conntrack ]; then
				grep -oE "$_priv_re" /proc/net/nf_conntrack 2>/dev/null | cut -d= -f2 | sort -u | \
					awk '{print $1 "|conntrack||permit"}' >> "$_tmpdev"
			fi
			unset _priv_re
			# Настроенные IP (full/exclude) — чтобы показать их, даже если устройство сейчас не активно
			for _ip in $(echo "${route_full} ${route_exclude}" | tr '+' ' '); do
				[ -n "$_ip" ] && echo "${_ip}|||permit" >> "$_tmpdev"
			done
			# Подключённые подсети всех интерфейсов (кроме lo) — "ip/prefix|broadcast".
			# Устройство = on-link сосед в одной из этих подсетей, но НЕ сам роутер и НЕ
			# broadcast. Так отсекаются собственные адреса роутера, broadcast, WAN/туннель и
			# удалённые служебные IP (видны в conntrack как src), а реальные LAN- и
			# VPN-клиенты (на своих интерфейсах) остаются.
			if_addr=$(ip -o -f inet addr show 2>/dev/null | \
				awk '$2 != "lo" { print $4 "|" ($5 == "brd" ? $6 : "") }' | tr '\n' ' ')
			# Вывод: режим list|full|exclude (маршрутизация) либо blocked (нет интернета)
			printf '{"ok":true,"devices":['
			KVAS_FULL="$(echo "$route_full" | tr '+' ' ')" KVAS_EXCL="$(echo "$route_exclude" | tr '+' ' ')" \
			KVAS_IFADDR="$if_addr" KVAS_LOCKED="$(iot_locked_macs | tr '\n' ' ')" \
			awk -F'|' "$AWK_JESC"'
				function ip2int(s,  p) { split(s, p, "."); return p[1]*16777216 + p[2]*65536 + p[3]*256 + p[4] }
				function in_lan(s,  di, i) {
					if (nlan == 0) return 1;              # нет данных об интерфейсах — не фильтруем
					if (s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0;
					di = ip2int(s);
					if (di in selfip) return 0;           # собственный адрес роутера
					if (di in bcast) return 0;            # broadcast
					for (i = 1; i <= nlan; i++)
						if (int(di / lblk[i]) * lblk[i] == lnet[i]) return 1;  # on-link сосед
					return 0;                             # вне всех подсетей (WAN-шлюз/служебное)
				}
				BEGIN {
					n = split(ENVIRON["KVAS_FULL"], a, " "); for (i=1;i<=n;i++) full[a[i]]=1;
					m = split(ENVIRON["KVAS_EXCL"], b, " "); for (i=1;i<=m;i++) excl[b[i]]=1;
					nl = split(ENVIRON["KVAS_LOCKED"], lk, " "); for (i=1;i<=nl;i++) if (lk[i] != "") locked[tolower(lk[i])]=1;
					k = split(ENVIRON["KVAS_IFADDR"], ifs, " "); nlan = 0;
					for (i = 1; i <= k; i++) {
						if (ifs[i] == "") continue;
						split(ifs[i], parts, "|");        # parts[1]=ip/prefix, parts[2]=broadcast
						if (split(parts[1], cc, "/") != 2) continue;
						pfx = cc[2] + 0; if (pfx < 1 || pfx > 32) continue;
						blk = 2 ^ (32 - pfx);
						self = ip2int(cc[1]);
						selfip[self] = 1;
						nlan++;
						lblk[nlan] = blk; lnet[nlan] = int(self / blk) * blk;
						if (parts[2] != "") bcast[ip2int(parts[2])] = 1;
						else bcast[lnet[nlan] + blk - 1] = 1;
					}
				}
				!seen[$1]++ {
					# настроенные (full/exclude) показываем всегда; остальные — только on-link
					if (!($1 in full) && !($1 in excl) && !in_lan($1)) next;
					ip=$1; name=$2; mac=$3; access=$4;
					name = jesc(name);
					if (access == "deny") mode = "blocked";
					else if (ip in full) mode = "full";
					else if (ip in excl) mode = "exclude";
					else mode = "list";
					iso = (mac != "" && tolower(mac) in locked) ? "true" : "false";
					if (f++) printf ",";
					printf "{\"ip\":\"%s\",\"name\":\"%s\",\"mac\":\"%s\",\"mode\":\"%s\",\"isolated\":%s}", ip, name, mac, mode, iso;
				}' "$_tmpdev" 2>/dev/null
			rm -f "$_tmpdev"
			echo ']}'
			;;
		device_set_mode)
			check_token "$token"
			ip=$(query_param ip)
			mac=$(query_param mac)
			mode=$(query_param mode)
			# mac идёт в RCI-JSON и jq-фильтр, ip — в kvas.conf: валидируем до использования
			if [ -n "$mac" ]; then mac=$(normalize_mac "$mac"); [ -z "$mac" ] && json_error "invalid mac"; fi
			[ -n "$ip" ] && { valid_ip_or_cidr "$ip" || json_error "invalid ip"; }
			case "$mode" in
				list|full|exclude|block) ;;
				*) json_error "mode must be list, full, exclude, or block" ;;
			esac
			# Блокировка интернета — штатный механизм Keenetic (hotspot deny), по MAC, персистентно
			if [ "$mode" = "block" ]; then
				[ -z "$mac" ] && json_error "устройство не зарегистрировано — блокировка недоступна"
				curl -s "127.0.0.1:79/rci/ip/hotspot/host" -X POST -H "Content-Type: application/json" \
					-d "{\"mac\":\"${mac}\",\"access\":\"deny\"}" >/dev/null 2>&1
				curl -s "127.0.0.1:79/rci/system/configuration/save" -X POST -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1
				# Проверяем, что блокировка действительно применилась (не рапортуем успех вслепую)
				verify=$(curl -s "127.0.0.1:79/rci/show/ip/hotspot" 2>/dev/null | \
					jq -r ".host[] | select(.mac==\"${mac}\") | .access" 2>/dev/null | head -1)
				if [ "$verify" = "deny" ]; then
					json_ok "internet blocked"
				else
					json_error "не удалось отключить интернет (проверьте, что устройство зарегистрировано)"
				fi
			fi
			# Маршрутные режимы: если устройство было заблокировано — сперва снять блокировку
			[ -z "$ip" ] && json_error "ip required"
			if [ -n "$mac" ]; then
				cur_access=$(curl -s "127.0.0.1:79/rci/show/ip/hotspot" 2>/dev/null | \
					jq -r ".host[] | select(.mac==\"${mac}\") | .access" 2>/dev/null | head -1)
				if [ "$cur_access" = "deny" ]; then
					curl -s "127.0.0.1:79/rci/ip/hotspot/host" -X POST -H "Content-Type: application/json" \
						-d "{\"mac\":\"${mac}\",\"access\":\"permit\"}" >/dev/null 2>&1
					curl -s "127.0.0.1:79/rci/system/configuration/save" -X POST -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1
				fi
			fi
			# Чистое переключение: убираем IP из всех поадресных ключей (вкл. route_by_list_ip
			# из вкладки «Маршрутизация», иначе остался бы невидимый дубль)
			changed=0
			for key in route_full_ip route_excluded_ip route_by_list_ip; do
				conf_list_edit "$key" + del "$ip"; rc=$?
				[ "$rc" -eq 2 ] && json_error "cannot write kvas.conf"
				[ "$rc" -eq 0 ] && changed=1
			done
			# Добавляем в целевой список (list = режим по умолчанию, отдельного ключа не требует)
			tgt=""
			[ "$mode" = "full" ] && tgt="route_full_ip"
			[ "$mode" = "exclude" ] && tgt="route_excluded_ip"
			if [ -n "$tgt" ]; then
				conf_list_edit "$tgt" + add "$ip"; rc=$?
				[ "$rc" -eq 2 ] && json_error "cannot write kvas.conf"
				[ "$rc" -eq 0 ] && changed=1
			fi
			# route refresh нужен только если конфиг реально поменялся
			if [ "$changed" = 0 ]; then
				json_ok "mode set"
			elif $KVAS_BIN route refresh >> /tmp/kvas-route-refresh.log 2>&1; then
				json_ok "mode set"
			else
				json_error "route refresh failed, see /tmp/kvas-route-refresh.log"
			fi
			;;
		device_set_isolation)
			# Изоляция устройства от панелей управления роутера (SSH/Telnet/RCI/
			# админка/веб-монитор) по MAC. Источник правды — IOT_LOCKDOWN_LIST,
			# применяется хуком netfilter.d/090-iot-lockdown (переживает перезагрузку
			# и пересборку правил NDM). НЕ влияет на интернет/DNS устройства.
			check_token "$token"
			mac=$(normalize_mac "$(query_param mac)")
			[ -z "$mac" ] && json_error "invalid mac"
			state=$(query_param state)
			case "$state" in on|off) ;; *) json_error "state must be on or off" ;; esac
			# Хук обязателен — проверяем ДО правки списка, чтобы при сломанном хуке
			# список не остался в состоянии, расходящемся с реальными правилами.
			[ -x "$IOT_LOCKDOWN_HOOK" ] || json_error "хук 090-iot-lockdown не установлен"
			mkdir -p "$(dirname "$IOT_LOCKDOWN_LIST")" 2>/dev/null
			touch "$IOT_LOCKDOWN_LIST" 2>/dev/null || json_error "cannot write lockdown list"
			# Убираем MAC (в любом регистре) и, если on, добавляем заново — без дублей
			_isotmp="${IOT_LOCKDOWN_LIST}.$$"
			grep -ivxF "$mac" "$IOT_LOCKDOWN_LIST" 2>/dev/null > "$_isotmp"
			[ "$state" = "on" ] && printf '%s\n' "$mac" >> "$_isotmp"
			mv -f "$_isotmp" "$IOT_LOCKDOWN_LIST" || json_error "cannot update lockdown list"
			# Переприменяем правила немедленно
			type=iptables table=filter "$IOT_LOCKDOWN_HOOK" >/dev/null 2>&1
			# Readback: убеждаемся, что правило реально применилось (не рапортуем вслепую).
			# iptables -S печатает MAC в верхнем регистре → grep -i.
			_ipt=$(command -v iptables 2>/dev/null || echo /opt/sbin/iptables)
			_present=0
			"$_ipt" -t filter -S _IOT_LOCKDOWN 2>/dev/null | grep -iqF -- "--mac-source ${mac}" && _present=1
			if [ "$state" = "on" ] && [ "$_present" = 0 ]; then
				json_error "правило не применилось (проверьте /opt/etc/ndm/netfilter.d/090-iot-lockdown)"
			fi
			if [ "$state" = "off" ] && [ "$_present" = 1 ]; then
				json_error "правило не снялось (проверьте /opt/etc/ndm/netfilter.d/090-iot-lockdown)"
			fi
			json_ok "isolation ${state}"
			;;
		route_guest_networks)
			check_token "$token"
			_tmp="/tmp/kvas_guest_nets.$$"
			tunnel_iface=$(grep "^INFACE_ENT=" "$KVAS_CONF_FILE" 2>/dev/null | cut -d= -f2)
			internet_iface=$(/opt/sbin/ip route 2>/dev/null | grep default | awk '{print $5}' | head -1)
			# Get interface list from ip addr
			/opt/sbin/ip -o -f inet addr show 2>/dev/null | awk '{
				iface = $2; sub(/@.*/, "", iface)
				ip = $4; sub(/\/.*/, "", ip)
				print iface "|" ip
			}' | sort -u > "$_tmp"
			# Query Keenetic API for VPN server pools
			api_tags=$(curl -s "127.0.0.1:79/rci/show/tags/" 2>/dev/null)
			_iface_prefix_by_pool() {
				local pool_ip="$1"
				[ -z "$pool_ip" ] && return
				local iface
				iface=$(/opt/sbin/ip -o addr show to "$pool_ip" 2>/dev/null | awk '{print $2}' | sed 's/@.*//' | head -1)
				[ -z "$iface" ] && return
				echo "$iface" | sed 's/[0-9]*$//'
			}
			if echo "$api_tags" | grep -qF 'vpn-oc' 2>/dev/null; then
				oc_ip=$(curl -s "127.0.0.1:79/rci/oc-server" 2>/dev/null | jq -r '.config."pool-start"' 2>/dev/null)
				if [ -n "$oc_ip" ]; then
					prefix=$(_iface_prefix_by_pool "$oc_ip")
					[ -z "$prefix" ] && prefix="oc"
					echo "${prefix}+|$oc_ip" >> "$_tmp"
				fi
			fi
			if echo "$api_tags" | grep -qF 'sstp' 2>/dev/null; then
				sstp_ip=$(curl -s "127.0.0.1:79/rci/sstp-server" 2>/dev/null | jq -r '.config."pool-start"' 2>/dev/null)
				if [ -n "$sstp_ip" ]; then
					prefix=$(_iface_prefix_by_pool "$sstp_ip")
					[ -z "$prefix" ] && prefix="sstp"
					echo "${prefix}+|$sstp_ip" >> "$_tmp"
				fi
			fi
			if echo "$api_tags" | grep -qF 'ipsec-l2tp' 2>/dev/null; then
				l2tp_ip=$(curl -s "127.0.0.1:79/rci/crypto/l2tp-server" 2>/dev/null | jq -r '."pool-start"' 2>/dev/null)
				if [ -n "$l2tp_ip" ]; then
					prefix=$(_iface_prefix_by_pool "$l2tp_ip")
					[ -z "$prefix" ] && prefix="l2tp"
					echo "${prefix}+|$l2tp_ip" >> "$_tmp"
				fi
			fi
			if echo "$api_tags" | grep -qF 'ipsec-xauth' 2>/dev/null; then
				ikev2_ip=$(curl -s "127.0.0.1:79/rci/crypto/virtual-ip-server-ikev2" 2>/dev/null | jq -r '."pool-start"' 2>/dev/null)
				[ -n "$ikev2_ip" ] && echo "xfrms+|$ikev2_ip" >> "$_tmp"
			fi
			printf '{"ok":true,"networks":['
			sep=""
			while IFS='|' read -r iface ip; do
				case "$iface" in
					lo|Bridge0|br0|ezcfg0|eth*|GigabitEthernet*|Port*|AccessPoint*|WifiMaster*|WifiStation*) continue ;;
				esac
				[ "$iface" = "$internet_iface" ] && continue
				[ "$iface" = "$tunnel_iface" ] && continue
				case "$iface" in
					br*)        desc="Гостевая сеть" ;;
					oc*)        desc="VPN-сервер OpenConnect" ;;
					sstp*)      desc="VPN-сервер SSTP" ;;
					l2tp*)      desc="VPN-сервер L2TP/IPsec" ;;
					xfrms*)     desc="VPN-сервер IKEv2/IPsec" ;;
					nwg*)       desc="WireGuard" ;;
					t2s*)       desc="KVAS прокси" ;;
					*)          desc="" ;;
				esac
				[ -z "$desc" ] && desc="$iface"
				printf '%s{"id":"%s","name":%s}' "$sep" "$iface" "$(json_str "$desc")"
				sep=","
			done < "$_tmp"
			rm -f "$_tmp"
			echo ']}'
			;;
		route_guest_add)
			check_token "$token"
			net=$(echo "$QUERY_STRING" | sed 's/.*net=//; s/&.*//; s/+/ /g; s/%2B/+/gi; s/%2F/\//gi; s/%20/ /g' 2>/dev/null)
			[ -z "$net" ] && json_error "net required"
			valid_ifname "$net" || json_error "invalid interface"
			conf_list_edit INFACE_GUEST_ENT , add "$net"; rc=$?
			if [ "$rc" -eq 1 ]; then
				json_ok "already added"
			elif [ "$rc" -ne 0 ]; then
				json_error "cannot write kvas.conf"
			else
				if $KVAS_BIN route refresh >> /tmp/kvas-route-refresh.log 2>&1; then
					json_ok "added $net"
				else
					json_error "route refresh failed, see /tmp/kvas-route-refresh.log"
				fi
			fi
			;;
		route_guest_del)
			check_token "$token"
			net=$(echo "$QUERY_STRING" | sed 's/.*net=//; s/&.*//; s/+/ /g; s/%2B/+/gi; s/%2F/\//gi; s/%20/ /g' 2>/dev/null)
			[ -z "$net" ] && json_error "net required"
			valid_ifname "$net" || json_error "invalid interface"
			conf_list_edit INFACE_GUEST_ENT , del "$net"; rc=$?
			if [ "$rc" -eq 1 ]; then
				json_ok "not found"
			elif [ "$rc" -ne 0 ]; then
				json_error "cannot write kvas.conf"
			else
				if $KVAS_BIN route refresh >> /tmp/kvas-route-refresh.log 2>&1; then
					json_ok "removed $net"
				else
					json_error "route refresh failed, see /tmp/kvas-route-refresh.log"
				fi
			fi
			;;
		*)
			json_error "unknown action"
			;;
	esac
}



main "$@"
