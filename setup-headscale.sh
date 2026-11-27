#!/bin/sh
# Интерактивная автонастройка Tailscale + Headscale на роутерах Keenetic (Entware MIPSel / ARM64)
set -eu
export LC_ALL=C
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DEFAULT_SERVER="https://headscale.tuttamdns.ru"
DEFAULT_TAILNET_DOMAIN="tailnet.tuttamdns.ru"
TS="/opt/bin/tailscale"
TSD="/opt/bin/tailscaled"
SERVICE="/opt/etc/init.d/S06tailscaled"
TMP_KEYFILE=""

cleanup() {
    [ -n "$TMP_KEYFILE" ] && [ -f "$TMP_KEYFILE" ] && rm -f "$TMP_KEYFILE"
}
trap cleanup EXIT INT TERM

info()  { printf '[INFO] %s\n' "$*"; }
ok()    { printf '[OK]   %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
fail()  { printf '[ERR]  %s\n' "$*" >&2; exit 1; }

ask() {
    # ask "Текст вопроса" "значение_по_умолчанию"
    _prompt=$1
    _def=${2:-}
    if [ -n "$_def" ]; then
        printf '%s [%s]: ' "$_prompt" "$_def" >&2
    else
        printf '%s: ' "$_prompt" >&2
    fi
    IFS= read -r _ans || _ans=""
    if [ -z "$_ans" ]; then
        printf '%s' "$_def"
    else
        printf '%s' "$_ans"
    fi
}

ask_yn() {
    # ask_yn "Вопрос" "y|n"
    _prompt=$1
    _def=${2:-n}
    if [ "$_def" = "y" ]; then
        _hint="Y/n"
    else
        _hint="y/N"
    fi
    printf '%s [%s]: ' "$_prompt" "$_hint" >&2
    IFS= read -r _ans || _ans=""
    [ -z "$_ans" ] && _ans=$_def
    case "$_ans" in
        [YyДд]*) return 0 ;;
        *)       return 1 ;;
    esac
}

# --- 1. Базовые проверки среды Keenetic / Entware ---
[ "$(id -u)" = "0" ] || fail "Запустите скрипт в SSH Entware от root."
[ -f /opt/etc/entware_release ] || [ -x /opt/bin/opkg ] || fail "Не найден Entware (/opt/bin/opkg)."
[ -c /dev/net/tun ] || fail "Отсутствует устройство /dev/net/tun. Проверьте поддержку TUN в прошивке."

ARCH=$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2!="all" && $2!="noarch" {a=$2} END {print a}')
case "$ARCH" in
    mipsel-3.4*|aarch64-3.10*)
        ok "Обнаружен Entware: $ARCH"
        ;;
    *)
        warn "Нестандартная архитектура Entware: ${ARCH:-не определена} (ожидались mipsel-3.4 или aarch64-3.10)."
        ask_yn "Продолжить установку на свой страх и риск?" "n" || exit 1
        ;;
esac

# --- 2. Автопроверка памяти (RAM и /opt), времени и сети ---
echo "------------------------------------------------------------"
echo "Диагностика роутера:"

# RAM из /proc/meminfo (в МБ, надёжнее BusyBox free)
if [ -r /proc/meminfo ]; then
    RAM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    RAM_AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    [ -z "$RAM_AVAIL_KB" ] && RAM_AVAIL_KB=$(awk '/^MemFree:/ {print $2}' /proc/meminfo)
    RAM_TOTAL_MB=$(( ${RAM_TOTAL_KB:-0} / 1024 ))
    RAM_AVAIL_MB=$(( ${RAM_AVAIL_KB:-0} / 1024 ))
    info "RAM: всего ${RAM_TOTAL_MB} МБ, доступно ${RAM_AVAIL_MB} МБ"
    if [ "$RAM_AVAIL_MB" -lt 48 ]; then
        warn "Мало свободной ОЗУ (${RAM_AVAIL_MB} МБ). Tailscale потребляет ~25-40 МБ RAM."
    fi
fi

# Флешка / хранилище /opt
OPT_TOTAL_KB=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $2}')
OPT_AVAIL_KB=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
OPT_TOTAL_MB=$(( ${OPT_TOTAL_KB:-0} / 1024 ))
OPT_AVAIL_MB=$(( ${OPT_AVAIL_KB:-0} / 1024 ))
info "Накопитель /opt: всего ${OPT_TOTAL_MB} МБ, свободно ${OPT_AVAIL_MB} МБ"
if [ "$OPT_AVAIL_MB" -lt 40 ]; then
    warn "На /opt меньше 40 МБ свободно (${OPT_AVAIL_MB} МБ). Установка пакета tailscale (~20-25 МБ) может не поместиться."
fi

# Системное время
CUR_YEAR=$(date +%Y 2>/dev/null || echo 1970)
if [ "$CUR_YEAR" -lt 2024 ]; then
    warn "Системное время на роутере сбито ($(date)). HTTPS-подключение к Headscale может не пройти из-за проверки сертификата!"
else
    ok "Системное время в норме: $(date '+%Y-%m-%d %H:%M:%S')"
fi

# Автоопределение LAN IP и подсети на br0
BR0_CIDR=$(ip -4 addr show dev br0 2>/dev/null | awk '$1=="inet" {print $2; exit}')
LAN_IP=${BR0_CIDR%/*}
LAN_PREFIX=${BR0_CIDR#*/}
if [ -z "$LAN_IP" ]; then
    warn "Не удалось автоматически определить IPv4 на интерфейсе br0."
    LAN_IP=$(ask "Введите LAN IP роутера вручную (например 192.168.1.1)" "192.168.1.1")
    LAN_PREFIX="24"
else
    ok "Автоопределён LAN IP (br0): $LAN_IP/$LAN_PREFIX"
fi

# Вычисление подсети (для /24 — стандартно X.Y.Z.0/24; иначе через ip route)
LAN_SUBNET=$(ip -4 route show dev br0 proto kernel scope link 2>/dev/null | awk '{print $1; exit}')
if [ -z "$LAN_SUBNET" ]; then
    LAN_SUBNET="$(printf '%s' "$LAN_IP" | awk -F. '{print $1"."$2"."$3".0"}')/${LAN_PREFIX:-24}"
fi

# --- 3. Ввод параметров Headscale и имени роутера ---
echo "------------------------------------------------------------"
SERVER=$(ask "Адрес сервера Headscale" "$DEFAULT_SERVER")
SERVER=${SERVER%/}

# Проверка доступности Headscale
if command -v curl >/dev/null 2>&1; then
    if curl -fsS -m 6 -I "$SERVER" >/dev/null 2>&1 || curl -sS -m 6 -o /dev/null "$SERVER" 2>/dev/null; then
        ok "Сервер Headscale отвечает: $SERVER"
    else
        warn "Не удалось достучаться до $SERVER. Проверьте интернет/DNS на роутере."
    fi
elif command -v wget >/dev/null 2>&1; then
    if wget -q --spider -T 6 "$SERVER" 2>/dev/null; then
        ok "Сервер Headscale отвечает: $SERVER"
    else
        warn "Не удалось достучаться до $SERVER. Проверьте интернет/DNS на роутере."
    fi
fi

while :; do
    NAME=$(ask "Имя роутера в Headscale (латиница, цифры, дефис, например keenetic-ofis)" "")
    case "$NAME" in
        ''|-*|*-|*[!a-z0-9-]*)
            warn "Недопустимое имя. Используйте только строчные латинские буквы, цифры и внутренние дефисы."
            ;;
        *)
            if [ "${#NAME}" -gt 63 ]; then
                warn "Имя длиннее 63 символов."
            else
                break
            fi
            ;;
    esac
done

echo ""
info "Pre-Auth Key (можно создать на VPS: sudo headscale preauthkeys create --user <ID> --expiration 15m)"
PREAUTH_KEY=$(ask "Вставьте Pre-Auth Key (или нажмите Enter для регистрации по ссылке)" "")

ADVERTISE_LAN="n"
if ask_yn "Открыть доступ ко всей локальной сети за роутером ($LAN_SUBNET)?" "n"; then
    ADVERTISE_LAN="y"
fi

# --- 4. Установка Tailscale и починка S06tailscaled ---
echo "------------------------------------------------------------"
if ! opkg status tailscale 2>/dev/null | grep -q '^Status: .* installed$'; then
    if [ -e "$TS" ] || [ -e "$TSD" ] || [ -e "$SERVICE" ]; then
        warn "Обнаружены файлы Tailscale, установленные не через opkg (возможно, старый TailScaleKeen)."
        if [ -f "$SERVICE" ] && grep -q -- '--tun=opkgtun0' "$SERVICE"; then
            warn "В $SERVICE найден параметр --tun=opkgtun0 (не работает на прошивках без OpkgTun)."
            if ask_yn "Сделать резервную копию в /opt/var/S06tailscaled.bak и заменить на --tun=tailscale0?" "y"; then
                mkdir -p /opt/var
                cp "$SERVICE" "/opt/var/S06tailscaled.bak.$(date +%Y%m%d%H%M%S)"
                sed -i 's/--tun=opkgtun0/--tun=tailscale0/g' "$SERVICE"
                ok "Исправлено на --tun=tailscale0 (бэкап сохранён в /opt/var/)."
            fi
        else
            ask_yn "Использовать найденную установку Tailscale как есть?" "y" || exit 1
        fi
    else
        info "Устанавливаю пакет tailscale из Entware..."
        opkg update || warn "opkg update завершился с предупреждениями, пробую установить пакет..."
        opkg install tailscale || fail "Не удалось установить пакет tailscale."
        ok "Пакет tailscale установлен."
    fi
else
    ok "Пакет tailscale уже установлен."
fi

[ -x "$TS" ] || fail "Не найден исполняемый файл $TS."
[ -f "$SERVICE" ] || fail "Не найден скрипт автозапуска $SERVICE."

# Проверка и починка --tun=opkgtun0 (даже если пакет был установлен)
if grep -q -- '--tun=opkgtun0' "$SERVICE"; then
    warn "В $SERVICE обнаружен --tun=opkgtun0."
    if ask_yn "Заменить --tun=opkgtun0 на --tun=tailscale0 (с бэкапом в /opt/var/)?" "y"; then
        mkdir -p /opt/var
        cp "$SERVICE" "/opt/var/S06tailscaled.bak.$(date +%Y%m%d%H%M%S)"
        sed -i 's/--tun=opkgtun0/--tun=tailscale0/g' "$SERVICE"
        ok "Параметр TUN исправлен на tailscale0."
    fi
fi

# Гарантируем автозапуск после перезагрузки Keenetic
chmod +x "$SERVICE"
if grep -q '^ENABLED=no' "$SERVICE"; then
    sed -i 's/^ENABLED=no/ENABLED=yes/' "$SERVICE"
    ok "Включён автозапуск (ENABLED=yes) в $SERVICE."
elif grep -q '^ENABLED=yes' "$SERVICE"; then
    ok "Автозапуск $SERVICE уже включён (ENABLED=yes)."
else
    warn "Проверьте вручную наличие ENABLED=yes в $SERVICE для автозапуска после перезагрузки."
fi

# --- 5. Запуск tailscaled и регистрация в Headscale ---
get_state() {
    "$TS" status --json 2>/dev/null | sed -n 's/.*"BackendState":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

STATE=$(get_state)
if [ -z "$STATE" ]; then
    info "Запускаю службу tailscaled..."
    "$SERVICE" start || true
fi

for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    STATE=$(get_state)
    case "$STATE" in
        ''|NoState|Starting) sleep 1 ;;
        *) break ;;
    esac
done

run_tailscale_up() {
    set -- "--login-server=$SERVER" "--hostname=$NAME" --accept-dns=false
    if [ "$ADVERTISE_LAN" = "y" ]; then
        set -- "$@" "--advertise-routes=$LAN_SUBNET"
    fi
    if [ -n "$PREAUTH_KEY" ]; then
        TMP_KEYFILE=$(mktemp /tmp/ts-key.XXXXXX)
        chmod 600 "$TMP_KEYFILE"
        printf '%s\n' "$PREAUTH_KEY" > "$TMP_KEYFILE"
        set -- "$@" "--auth-key=file:$TMP_KEYFILE"
        info "Выполняю автоматическую регистрацию по Pre-Auth Key..."
    else
        echo ""
        info "Откройте ссылку ниже и подтвердите регистрацию на VPS:"
        info "sudo headscale auth register --auth-id <КЛЮЧ_СО_СТРАНИЦЫ> --user routers"
        echo ""
    fi
    "$TS" up "$@"
    cleanup
}

case "$STATE" in
    NeedsLogin|Stopped)
        run_tailscale_up
        ;;
    Running)
        PREFS=$("$TS" debug prefs 2>/dev/null || true)
        CUR_CTRL=$(printf '%s\n' "$PREFS" | sed -n 's/.*"ControlURL":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
        CUR_HOST=$(printf '%s\n' "$PREFS" | sed -n 's/.*"Hostname":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
        ok "Tailscale уже запущен (узел: ${CUR_HOST:-?}, сервер: ${CUR_CTRL:-?})."
        if [ "${CUR_CTRL%/}" != "$SERVER" ] || [ "$CUR_HOST" != "$NAME" ] || [ "$ADVERTISE_LAN" = "y" ]; then
            if ask_yn "Применить новые параметры (имя=$NAME, сервер=$SERVER)?" "y"; then
                run_tailscale_up
            fi
        fi
        ;;
    *)
        fail "Неожиданное состояние tailscaled: '${STATE:-недоступен}'. Проверьте $SERVICE status и логи."
        ;;
esac

# Ожидаем выдачи Tailscale IPv4 (до 10 сек)
TS_IP=""
for _i in 1 2 3 4 5 6 7 8 9 10; do
    TS_IP=$("$TS" ip -4 2>/dev/null | head -n 1 || true)
    [ -n "$TS_IP" ] && break
    sleep 1
done
[ -n "$TS_IP" ] || fail "Headscale ещё не назначил IPv4. Проверьте регистрацию и повторите запуск."
ok "Получен Tailscale IPv4: $TS_IP"

# Пытаемся узнать DNS-имя узла из status --json
DNS_NAME=$("$TS" status --json 2>/dev/null | sed -n 's/.*"DNSName":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)
DNS_NAME=${DNS_NAME%.}
[ -z "$DNS_NAME" ] && DNS_NAME="${NAME}.${DEFAULT_TAILNET_DOMAIN}"

# --- 6. Автодетект локальных портов и выбор сервисов для Tailscale Serve ---
port_is_open() {
    _p=$1
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${_p}$" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${_p}$" && return 0
    fi
    # Fallback: проверка через /proc/net/tcp (порт в hex)
    _hex=$(printf '%04X' "$_p")
    awk -v h=":$_hex" 'NR>1 && $4=="0A" && index($2, h) {found=1} END {exit !found}' /proc/net/tcp 2>/dev/null && return 0
    return 1
}

# Определяем локальный порт SSH (222 или 22)
SSH_PORT=""
if port_is_open 222; then
    SSH_PORT=222
elif port_is_open 22; then
    SSH_PORT=22
fi

HAS_WEB=0;  port_is_open 80   && HAS_WEB=1
HAS_SSH=0;  [ -n "$SSH_PORT" ] && HAS_SSH=1
HAS_XKEEN=0; port_is_open 1000 && HAS_XKEEN=1
HAS_ZASH=0; port_is_open 9090 && HAS_ZASH=1

DEFAULT_SEL=""
[ "$HAS_WEB" = 1 ]   && DEFAULT_SEL="$DEFAULT_SEL 1"
[ "$HAS_SSH" = 1 ]   && DEFAULT_SEL="$DEFAULT_SEL 2"
[ "$HAS_XKEEN" = 1 ] && DEFAULT_SEL="$DEFAULT_SEL 3"
[ "$HAS_ZASH" = 1 ]  && DEFAULT_SEL="$DEFAULT_SEL 4"
DEFAULT_SEL=$(printf '%s' "$DEFAULT_SEL" | sed 's/^ //')
[ -z "$DEFAULT_SEL" ] && DEFAULT_SEL="1"

echo "------------------------------------------------------------"
echo "Выберите сервисы, которые нужно открыть через Tailscale Serve:"
printf '  1) Веб-панель Keenetic  (локальный :80   -> Serve :8081) [%s]\n' "$( [ "$HAS_WEB" = 1 ] && echo 'НАЙДЕН' || echo 'не найден' )"
printf '  2) SSH Entware          (локальный :%-3s -> Serve :2222) [%s]\n' "${SSH_PORT:-222}" "$( [ "$HAS_SSH" = 1 ] && echo 'НАЙДЕН' || echo 'не найден' )"
printf '  3) XKeenUI              (локальный :1000 -> Serve :8082) [%s]\n' "$( [ "$HAS_XKEEN" = 1 ] && echo 'НАЙДЕН' || echo 'не найден' )"
printf '  4) Zashboard / Mihomo   (локальный :9090 -> Serve :8083) [%s]\n' "$( [ "$HAS_ZASH" = 1 ] && echo 'НАЙДЕН' || echo 'не найден' )"
echo "  0) Ничего не открывать (пропустить)"
echo ""
SEL=$(ask "Введите номера через пробел (Enter = все найденные)" "$DEFAULT_SEL")

OPEN_WEB=0; OPEN_SSH=0; OPEN_XKEEN=0; OPEN_ZASH=0
for _item in $SEL; do
    case "$_item" in
        1) OPEN_WEB=1 ;;
        2) OPEN_SSH=1 ;;
        3) OPEN_XKEEN=1 ;;
        4) OPEN_ZASH=1 ;;
        0) OPEN_WEB=0; OPEN_SSH=0; OPEN_XKEEN=0; OPEN_ZASH=0; break ;;
    esac
done

apply_serve_http() {
    _ext=$1; _loc=$2; _label=$3
    info "Открываю $_label: :$_ext -> http://$LAN_IP:$_loc"
    "$TS" serve --bg --http="$_ext" "http://$LAN_IP:$_loc" || warn "Не удалось настроить Serve для $_label (:$_ext)."
}

apply_serve_tcp() {
    _ext=$1; _loc=$2; _label=$3
    info "Открываю $_label (TCP): :$_ext -> tcp://$LAN_IP:$_loc"
    "$TS" serve --bg --tcp="$_ext" "tcp://$LAN_IP:$_loc" || warn "Не удалось настроить Serve для $_label (:$_ext)."
}

[ "$OPEN_WEB" = 1 ]   && apply_serve_http 8081 80 "Веб-панель Keenetic"
if [ "$OPEN_SSH" = 1 ]; then
    SSH_LOC=$(ask "Локальный порт SSH на роутере" "${SSH_PORT:-222}")
    apply_serve_tcp 2222 "$SSH_LOC" "SSH Entware"
fi
[ "$OPEN_XKEEN" = 1 ] && apply_serve_http 8082 1000 "XKeenUI"
[ "$OPEN_ZASH" = 1 ]  && apply_serve_http 8083 9090 "Zashboard / Mihomo"

# Дополнительные пользовательские порты
CUSTOM_LIST=""
while ask_yn "Добавить ещё какой-нибудь свой порт?" "n"; do
    C_PROTO=$(ask "Протокол (http или tcp)" "http")
    C_LOC=$(ask "Локальный порт на роутере (например 8090)" "")
    C_EXT=$(ask "Внешний порт в Tailscale Serve (например 8090)" "$C_LOC")
    [ -z "$C_LOC" ] || [ -z "$C_EXT" ] && { warn "Порт не указан, пропускаю."; continue; }
    case "$C_PROTO" in
        tcp|TCP)
            apply_serve_tcp "$C_EXT" "$C_LOC" "Свой TCP :$C_LOC"
            CUSTOM_LIST="${CUSTOM_LIST}  - Custom TCP :${C_LOC} -> ${TS_IP}:${C_EXT}\n"
            ;;
        *)
            apply_serve_http "$C_EXT" "$C_LOC" "Свой HTTP :$C_LOC"
            CUSTOM_LIST="${CUSTOM_LIST}  - Custom HTTP :${C_LOC} -> http://${DNS_NAME}:${C_EXT}/\n"
            ;;
    esac
done

# --- 7. Итоговая шпаргалка ---
echo ""
echo "============================================================"
echo "  ГОТОВО! Шпаргалка для подключения к роутеру '$NAME'"
echo "============================================================"
printf '  Tailscale IPv4 : %s\n' "$TS_IP"
printf '  Домен узла     : %s\n' "$DNS_NAME"
printf '  LAN IP (br0)   : %s (%s)\n' "$LAN_IP" "$LAN_SUBNET"
echo "------------------------------------------------------------"
[ "$OPEN_WEB" = 1 ]   && printf '  Keenetic UI    : http://%s:8081/\n' "$DNS_NAME"
[ "$OPEN_XKEEN" = 1 ] && printf '  XKeenUI        : http://%s:8082/\n' "$DNS_NAME"
[ "$OPEN_ZASH" = 1 ]  && printf '  Zashboard      : http://%s:8083/ui\n' "$DNS_NAME"
[ "$OPEN_SSH" = 1 ]   && printf '  SSH команда    : ssh root@%s -p 2222\n' "$TS_IP"
[ -n "$CUSTOM_LIST" ] && printf '%b' "$CUSTOM_LIST"
if [ "$ADVERTISE_LAN" = "y" ]; then
    echo "------------------------------------------------------------"
    printf '  Subnet Route   : %s (не забудьте одобрить маршрут в Headscale/Headplane!)\n' "$LAN_SUBNET"
fi
echo "============================================================"
echo ""
info "Текущий статус Tailscale Serve:"
"$TS" serve status || true
