# Инструкция для другой нейросети: удалённый доступ к Keenetic через Headscale

Этот файл передаёт проверенную конфигурацию и порядок действий для подключения роутеров Keenetic или роутеров с KeeneticOS и Entware к частной сети Tailscale под управлением Headscale.

## Готовый запрос для другой нейросети

Скопируй этот текст вместе с файлом:

> Ты настраиваешь удалённый доступ к роутеру Keenetic или к роутеру с KeeneticOS и Entware через мой Headscale. Следуй runbook по шагам. Сначала собери диагностику и не выполняй изменения до определения архитектуры, LAN-адреса, локальных портов и текущего состояния Tailscale. Используй `https://headscale.tuttamdns.ru` и пользователя `alekras`, если я не указал другие значения. Регистрацию узла выполняй на VPS через `sudo headscale auth register`. Не запрашивай пароли, приватные ключи и токены. Для доступа к панели Keenetic, XKeenUI, SSH Entware и Zashboard используй Tailscale Serve, если прямой доступ по Tailscale не проходит. После каждого шага показывай ожидаемый результат, проверяй его и отдельно отмечай неподтверждённые части.

## Постоянные параметры сети

- Контроллер Headscale: `https://headscale.tuttamdns.ru`
- Пользователь Headscale: `alekras`
- Домен MagicDNS: `tailnet.tuttamdns.ru`
- Регистрация узла на VPS выполняется командой:

```sh
sudo headscale auth register --auth-id <КЛЮЧ_СО_СТРАНИЦЫ_РЕГИСТРАЦИИ> --user alekras
```

Никогда не запрашивай у пользователя пароли, приватные ключи, `auth-id`, ключи Tailscale или `secret` Mihomo. В документации используй только placeholders.

## Цель подключения

Для каждого роутера нужно обеспечить доступ к:

| Сервис | Локальный адрес | Рекомендуемый адрес в tailnet |
|---|---|---|
| Штатная панель Keenetic | `<LAN_IP>:80` | `<hostname>.tailnet.tuttamdns.ru:8081` |
| XKeenUI | `<LAN_IP>:1000` | `<hostname>.tailnet.tuttamdns.ru:8082` |
| SSH Entware | `<LAN_IP>:222` или `<LAN_IP>:22` | `<hostname>.tailnet.tuttamdns.ru:2222` |
| Mihomo/Zashboard | `<LAN_IP>:9090` | `<hostname>.tailnet.tuttamdns.ru:8083/ui` |

Порты `8081`, `8082`, `2222` и `8083` являются внешними портами Tailscale Serve. Они не обязаны совпадать с локальными портами роутера.

## Что спросить перед изменениями

Уточни у пользователя:

1. LAN-адрес роутера, например `192.168.1.1`.
2. Уникальное имя узла в нижнем регистре латиницей, цифрами и дефисами, например `artur-yuvelir-roditeli`.
3. Доступ к SSH Entware от root.
4. Локальный SSH-порт. На разных устройствах встречаются `22` и `222`.
5. Архитектуру Entware и наличие `/dev/net/tun`.

Если роутер не является официальным Keenetic, не предлагай обновление прошивки или изменение набора компонентов без явного подтверждения пользователя. Сначала используй доступный пакет Tailscale из Entware.

## Первичная диагностика роутера

Выполняй команды в SSH-оболочке Entware от root:

```sh
uname -m
opkg print-architecture
df -h /opt
ls -l /dev/net/tun
ndmc -c "show version"
opkg status tailscale
ls -l /opt/bin/tailscale /opt/bin/tailscaled /opt/etc/init.d/S06tailscaled
ps
```

Ожидаемые варианты:

- ARM64: `aarch64`, Entware `aarch64-3.10`.
- MIPSel: `mips` в `uname -m`, но Entware `mipsel-3.4` или `mipsel-3.4_kn`.
- Наличие `/dev/net/tun` необходимо для Linux-интерфейса Tailscale, но само по себе не означает поддержку KeeneticOS-интерфейса `OpkgTun`.

Определяй локальные сервисы так:

```sh
netstat -lntp | grep -E ':(22|222|80|1000|9090)[[:space:]]'
```

Если `/opt/bin/grep` завершается с `Bus error`, используй BusyBox:

```sh
/opt/bin/busybox grep -E ':(22|222|80|1000|9090)[[:space:]]'
```

Не объявляй причину `Bus error` установленной без дополнительных данных. Не запускай массовый `opkg upgrade` для обхода этой ошибки.

## Установка Tailscale из Entware

Если Tailscale ещё не установлен:

```sh
opkg update
opkg install tailscale
/opt/etc/init.d/S06tailscaled start
/opt/etc/init.d/S06tailscaled status
```

Проверь версию и init-скрипт:

```sh
/opt/bin/tailscale version
cat /opt/etc/init.d/S06tailscaled
```

Для штатной установки Entware нормальный init-скрипт содержит `--state`, `--statedir` и не содержит `--tun=opkgtun0`. Такой клиент использует обычный Linux-интерфейс `tailscale0`.

## TailScaleKeen и OpkgTun

TailScaleKeen подходит для ARM64 Entware `aarch64-3.10`, если прошивка поддерживает создание `OpkgTun`. Проверяй это по фактической команде:

```sh
ndmc -c "interface OpkgTun0"
```

Ответ:

```text
unsupported interface type: "OpkgTun"
```

означает, что текущая прошивка не поддерживает этот тип. Наличие `/dev/net/tun` это не исправляет.

На прошивке без OpkgTun возможен fallback:

1. Сохрани копию `/opt/etc/init.d/S06tailscaled` вне каталога автозапуска.
2. Если в скрипте есть `--tun=opkgtun0`, замени только этот параметр на `--tun=tailscale0`.
3. Запусти службу и проверь `status`.
4. Не оставляй резервную копию с именем `S*` в `/opt/etc/init.d/`.

## Регистрация в Headscale

На роутере выполни:

```sh
/opt/bin/tailscale up \
  --login-server=https://headscale.tuttamdns.ru \
  --hostname=<УНИКАЛЬНОЕ_ИМЯ> \
  --accept-dns=false
```

Открой ссылку, которую покажет Tailscale. Команду со страницы выполняй на VPS, добавив `sudo` и пользователя `alekras`. После ответа `Node ... registered` на роутере проверь:

```sh
/opt/bin/tailscale status
/opt/bin/tailscale ip -4
```

При повторной регистрации узел может получить новый IP `100.64.0.x`, а Serve-конфигурация может отсутствовать. Всегда заново проверяй IP и `tailscale serve status`.

## Настройка Tailscale Serve

Сначала проверь существующую конфигурацию:

```sh
/opt/bin/tailscale serve status
```

Не сбрасывай и не перезаписывай существующий Serve без просмотра вывода. Если нужных правил нет, добавляй их по одному, используя фактический LAN-адрес и локальные порты.

### Keenetic

```sh
/opt/bin/tailscale serve --bg --http=8081 http://<LAN_IP>:80
```

Открывай имя, показанное Serve, например:

```text
http://artur-yuvelir-roditeli.tailnet.tuttamdns.ru:8081/
```

Обращение к IP Tailscale с портом Serve может вернуть `404`, поэтому для HTTP Serve используй имя узла.

### XKeenUI

```sh
/opt/bin/tailscale serve --bg --http=8082 http://<LAN_IP>:1000
```

Адрес:

```text
http://<hostname>.tailnet.tuttamdns.ru:8082/
```

### SSH Entware

Если SSH Entware слушает `222`:

```sh
/opt/bin/tailscale serve --bg --tcp=2222 tcp://<LAN_IP>:222
```

Если SSH Entware слушает `22`, замени конечный порт:

```sh
/opt/bin/tailscale serve --bg --tcp=2222 tcp://<LAN_IP>:22
```

В Termius используй имя узла или IP Tailscale, внешний порт `2222`. Пример подтверждённого подключения:

```text
Host: 100.64.0.18
Port: 2222
User: root
```

### Zashboard и Mihomo

Если Mihomo слушает HTTP на `9090`:

```sh
/opt/bin/tailscale serve --bg --http=8083 http://<LAN_IP>:9090
```

Открывай:

```text
http://<hostname>.tailnet.tuttamdns.ru:8083/ui
```

В форме Zashboard укажи HTTP, hostname узла, порт `8083`, пустой дополнительный путь и `secret` Mihomo, если он задан. Значение `secret` не передавай в чат или GitHub.

## Проверка после настройки

На ПК, подключённом к Headscale:

```powershell
tailscale status
tailscale ping <TAILSCALE_IP>
```

Проверь HTTP-адреса в браузере и TCP-порты из Termius. На роутере снова выполни:

```sh
/opt/bin/tailscale serve status
```

Для проверки сервиса с Windows можно использовать:

```powershell
Test-NetConnection <TAILSCALE_IP> -Port 2222
```

Результат считается подтверждённым только после проверки из другой сети и после перезагрузки, если пользователь может сохранить независимый доступ к роутеру. Отдельно отмечай, какие проверки ещё не выполнены.

## Известные состояния и ошибки

- `Logged out` означает, что демон запущен, но клиент ещё не зарегистрирован.
- Новый IP после повторного `tailscale up` означает, что нужно обновить адреса в Termius и ссылках.
- `No serve config` означает, что правила Serve нужно создать заново.
- `unsupported interface type: "OpkgTun"` означает отсутствие поддержки OpkgTun в KeeneticOS.
- `create table: get tables: netlink receive: invalid argument` и ошибки цепочки `ts-input` могут означать, что прямые входящие порты Tailscale не работают. В этом случае используй Tailscale Serve с проксированием на LAN-адрес роутера.
- Если локальный сервис отвечает по LAN, но прямой `100.64.0.x:<порт>` не отвечает, это не доказывает поломку самого сервиса. Проверь Serve и его целевой локальный порт.

## Известные проверенные устройства

| Имя | Модель и архитектура | Tailscale IP | Особенности |
|---|---|---:|---|
| `moy-router-1011` | MIPSel, Entware `mipsel-3.4` | `100.64.0.9` | SSH Entware `222`, прямой Tailscale-клиент |
| `nesterov-c960` | ARM64 C960 KN-1012, прошивка без OpkgTun | `100.64.0.12` | Tailscale через `tailscale0`, Serve для Keenetic |
| `ukhanov` | ARM64 Hopper KN-3811 | `100.64.0.14` | Serve `8081`, `8082`, `2222`, `8083`; ошибка `ts-input` |
| `artur-yuvelir-roditeli` | MIPSel N6 AX1800 KN-2311, KeeneticOS 5.0.7 | `100.64.0.18` | SSH Serve `2222` → LAN `222`, Keenetic Serve `8081`; Zashboard Serve `8083` настроен, доступ требует отдельной проверки |

## Правила для нейросети

Всегда сначала собери модель, архитектуру, LAN-адрес, локальные порты и текущий статус Tailscale. Не придумывай имя, IP, SSH-порт или путь к Mihomo. Не отправляй пользователя к обновлению прошивки неофициального роутера. Не меняй firewall, маршруты и компоненты без диагностического вывода и независимого доступа. После каждого изменения показывай команду, ожидаемый результат и способ проверки. В конце перечисляй подтверждённые и неподтверждённые части настройки.
