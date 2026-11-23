#!/bin/sh
# Запуск в SSH Entware от root. Параметры описаны в Headscale_Keenetic_MIPSel.md.
set -eu
export LC_ALL=C
export PATH="/opt/bin:/opt/sbin:$PATH"
server=https://headscale.tuttamdns.ru
ts=/opt/bin/tailscale
service=/opt/etc/init.d/S06tailscaled

fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail 'Запуск: sh setup-headscale.sh ИМЯ LAN_IP [ФАЙЛ_КЛЮЧА]'
name=$1
lan=$2
keyfile=${3:-}
case "$name" in ''|-*|*-|*[!a-z0-9-]*) fail 'Имя: строчные латинские буквы, цифры и внутренние дефисы.';; esac
[ "${#name}" -le 63 ] || fail 'Имя длиннее 63 символов.'
[ "$(id -u)" = 0 ] || fail 'Запустите в оболочке Entware от root.'
[ -c /dev/net/tun ] || fail 'Отсутствует устройство /dev/net/tun.'
opkg print-architecture | grep -q '^arch mipsel-3\.4 ' || fail 'Требуется Entware mipsel-3.4.'
ip -4 addr show dev br0 | awk -v addr="$lan" '$1=="inet" {split($2,a,"/"); if (a[1]==addr) ok=1} END {exit !ok}' ||
    fail 'LAN_IP должен совпадать с IPv4 домашнего интерфейса br0. Проверьте ip -4 addr.'
if [ -n "$keyfile" ]; then
    [ -f "$keyfile" ] && [ -r "$keyfile" ] && [ -s "$keyfile" ] || fail 'Проверьте файл одноразового ключа.'
fi

if ! opkg status tailscale | grep -q '^Status: .* installed$'; then
    [ ! -e "$ts" ] && [ ! -e "$service" ] && [ ! -e /opt/bin/tailscaled ] ||
        fail 'Обнаружена другая установка Tailscale. Сначала проверьте, как она управляется.'
    opkg update
    opkg install tailscale
fi
[ -x "$ts" ] && [ -x "$service" ] || fail 'Проверьте файлы установленного пакета tailscale.'

state() {
    "$ts" status --json 2>/dev/null | sed -n 's/^[[:space:]]*"BackendState":[[:space:]]*"\([^"]*\)".*/\1/p'
}
s=$(state)
if [ -z "$s" ]; then
    "$service" start
fi
for n in 1 2 3 4 5 6 7 8 9 10; do
    s=$(state)
    case "$s" in ''|NoState|Starting) sleep 1;; *) break;; esac
done
case "$s" in
    NeedsLogin)
        set -- "--login-server=$server" "--hostname=$name" --accept-dns=false
        if [ -n "$keyfile" ]; then
            set -- "$@" "--auth-key=file:$keyfile"
        else
            printf '%s\n' 'Откройте ссылку Tailscale. На VPS подтвердите регистрацию под пользователем alekras.'
        fi
        "$ts" up "$@"
        ;;
    Running)
        # При повторном запуске проверяем принадлежность узла до настройки Serve.
        prefs=$("$ts" debug prefs)
        control=$(printf '%s\n' "$prefs" | sed -n 's/^[[:space:]]*"ControlURL":[[:space:]]*"\([^"]*\)".*/\1/p')
        host=$(printf '%s\n' "$prefs" | sed -n 's/^[[:space:]]*"Hostname":[[:space:]]*"\([^"]*\)".*/\1/p')
        [ "${control%/}" = "$server" ] && [ "$host" = "$name" ] ||
            fail 'Клиент уже подключён. Проверьте имя устройства и адрес контроллера.'
        ;;
    *) fail "Состояние tailscaled: ${s:-недоступен}. Проверьте службу и tailscale status.";;
esac
addr=$("$ts" ip -4)
[ -n "$addr" ] || fail 'Headscale ещё не назначил IPv4. Проверьте регистрацию и повторите запуск.'
serve=$("$ts" serve status --json)
case "$(printf '%s' "$serve" | tr -d '[:space:]')" in
    '{}'|null)
    "$ts" serve --bg --http=8081 "http://$lan:80"
    ;;
    '')
    fail 'Не удалось прочитать конфигурацию Serve.'
    ;;
    *)
    printf '%s\n' 'Уже настроен Serve. Сверьте адрес и порт панели с действующей конфигурацией.'
    ;;
esac
"$ts" serve status
printf 'Проверка с устройства в Headscale: XKeenUI http://%s:1000/ и SSH Entware %s:222 (если используется порт 222).\n' "$addr" "$addr"
