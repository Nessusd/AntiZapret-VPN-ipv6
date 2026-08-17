# AntiZapret VPN IPv6

Форк [AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN) с упором на
dual-stack.

Задача простая: добавить IPv6 и не разломать штатный IPv4. Если IPv6 выключен,
новая логика в старую схему не лезет.

## Что уже едет

- OpenVPN, WireGuard и AmneziaWG работают в IPv4+IPv6.
- AAAA для доменов AntiZapret уходит через туннель.
- Full VPN получает IPv6 default route.
- На сервере подняты отдельные `ip6tables`, IPv6-наборы `ipset` и NAT66.
- Старые адреса, ключи и IPv4-профили сохраняются при миграции.
- После setup и восстановления из backup приватные каталоги EasyRSA и
  `/etc/wireguard` зажимаются: каталогам `0700`, файлам `0600`.
- IPv6 можно полностью выключить через setup.
- BGP включается отдельно и по умолчанию не ставится.
- WARP можно включить отдельно для AntiZapret VPN и full VPN.

IPv6-списки лежат рядом с IPv4:

```text
setup/root/antizapret/download/
├── cloudflare-ips.txt
├── cloudflare-ips6.txt
├── telegram-ips.txt
├── telegram-ips6.txt
└── ...
```

Сейчас есть IPv6-списки для Cloudflare, Amazon, Google, Telegram, Hetzner,
DigitalOcean, OVH, Meta/WhatsApp, Roblox и Akamai.

Fastly не используется. Для Discord нормального источника IPv6-префиксов пока
нет.

## WARP

WARP регистрируется при старте сервиса. Отдельно можно завернуть:

- `antizapret-*`;
- `vpn-*`.

Если WARP не поднялся, трафик уходит через обычный uplink сервера. Fail-closed
тут нет.

Если dual-stack WARP не стартовал, выполняется повторная попытка только с IPv4.
Рабочий IPv4 из-за проблем WARP IPv6 не режется.

## BGP

BGP нужен роутерам, которым неудобно принимать жирный список статических
маршрутов.

Под капотом отдельный BIRD 2:

- слушает TCP/179 только из VPN-сетей;
- отдаёт IPv4 и IPv6 одним пиром;
- ничего не принимает от клиентов;
- свои таблицы в FIB сервера не льёт;
- обычных клиентов не трогает.

При ответе `n` установщик не ставит BIRD, не создаёт unit и не открывает
TCP/179.

Режим клиента:

- `static` — штатная раздача маршрутов;
- `bgp` — маршруты забирает BGP-демон клиента.

Все клиенты могут использовать ASN `4200000291`. Сервер разводит их по tunnel
IP. `router-id` должен быть уникальным.

Серверные адреса:

| Транспорт | BGP peer |
|---|---|
| OpenVPN UDP | `10.29.0.1` |
| OpenVPN TCP | `10.29.4.1` |
| WireGuard | `10.29.8.1` |

При альтернативной сетке `10` меняется на `172`.

## Известные грабли

### RouterOS и OpenVPN IPv6

RouterOS 7.19.6 сохраняет только последний из нескольких `route-ipv6`.
Большой push также может закончиться сообщением:

```text
received OVPN option length exceeds limit
```

Для длинных списков используйте BGP.

### Маршрутизируемый префикс клиента

OpenVPN-клиенту в режиме роутера можно назначить глобальный префикс от `/48`
до `/64`.

Схема ещё не обкатана во всех комбинациях. Автоматическая установка серверного
маршрута сейчас зависит от OpenVPN DCO.

### Выход в IPv6

ULA внутри туннеля не даёт интернет сам по себе. Нужны:

- глобальный IPv6 и рабочий default route на uplink либо живой WARP IPv6;
- разрешённый forwarding.

## Требования

- Ubuntu 24.04+ или Debian 13+;
- отдельный сервер/VPS;
- публичный IPv4;
- глобальный IPv6, если IPv6 не выводится через WARP;
- запуск от `root`.

Setup правит firewall, sysctl, systemd и сетевые сервисы. Заодно сносит UFW,
Firewalld, AppArmor и пачку лишних для VPN пакетов.

На общей хозяйской машине его лучше не пускать.

## Установка

```sh
bash <(wget -qO- --no-hsts --inet4-only https://raw.githubusercontent.com/Nessusd/AntiZapret-VPN-ipv6/main/setup.sh)
```

Для IPv6 оставить:

```text
Disable IPv6 on this server? [y/n]: n
```

Для BGP:

```text
Enable private BGP route delivery for router clients? [y/n]: y
```

ASN по умолчанию:

```text
server: 4200000290
client: 4200000291
```

Перед повторной установкой можно снять backup:

```sh
/root/antizapret/client.sh 8
```

Архив проверяется до публикации, кладётся атомарно и получает режим `0600`.

## Клиенты

Меню:

```sh
/root/antizapret/client.sh
```

Профили:

```text
/root/antizapret/client/openvpn/
/root/antizapret/client/wireguard/
/root/antizapret/client/amneziawg/
```

## RouterOS 7

Команды проверены на RouterOS 7.19.6 и 7.23.1. Поменять под свой роутер:

- `10.29.0.2` — tunnel IP клиента и его `router-id`;
- `10.29.0.1` — BGP peer сервера;
- `4200000290` — ASN сервера;
- `4200000291` — ASN клиента;
- `main` — таблица маршрутизации.

Для OpenVPN TCP peer сервера — `10.29.4.1`, для WireGuard — `10.29.8.1`.
При альтернативной сетке `10` меняется на `172`.

Фильтры:

```routeros
/routing/filter/rule
add chain=antizapret-bgp-in rule="if (afi ipv4 && bgp-input-remote-as == 4200000290 && bgp-large-communities includes 4200000290:29:4) { accept; }"
add chain=antizapret-bgp-in rule="if (afi ipv6 && bgp-input-remote-as == 4200000290 && bgp-large-communities includes 4200000290:29:6) { accept; }"
add chain=antizapret-bgp-in rule="reject;"
add chain=antizapret-bgp-out rule="reject;"
```

RouterOS 7.19:

```routeros
/routing/bgp/connection
add name=antizapret-bgp as=4200000291 router-id=10.29.0.2 local.address=10.29.0.2 local.role=ebgp remote.address=10.29.0.1/32 remote.as=4200000290 afi=ip,ipv6 routing-table=main connect=yes listen=no input.filter=antizapret-bgp-in input.limit-process-routes-ipv4=10000 input.limit-process-routes-ipv6=10000 output.filter-chain=antizapret-bgp-out
```

RouterOS 7.20+:

```routeros
/routing/bgp/instance
add name=antizapret-bgp as=4200000291 router-id=10.29.0.2

/routing/bgp/connection
add name=antizapret-bgp instance=antizapret-bgp local.address=10.29.0.2 local.role=ebgp remote.address=10.29.0.1/32 remote.as=4200000290 afi=ip,ipv6 routing-table=main connect=yes listen=no input.filter=antizapret-bgp-in input.limit-process-routes-ipv4=10000 input.limit-process-routes-ipv6=10000 output.filter-chain=antizapret-bgp-out
```

Проверка:

```routeros
/routing/bgp/session/print detail where name~"antizapret-bgp"
/ip/route/print count-only where protocol=bgp
/ipv6/route/print count-only where protocol=bgp
```

Повторный импорт создаст дубли. Перед пересборкой удалить только объекты
AntiZapret:

```routeros
/routing/bgp/connection/remove [find where name="antizapret-bgp"]
/routing/bgp/instance/remove [find where name="antizapret-bgp"]
/routing/filter/rule/remove [find where chain="antizapret-bgp-in"]
/routing/filter/rule/remove [find where chain="antizapret-bgp-out"]
```

## Апдейты

Планировщик запускается ежедневно в `02:00` с рандомной задержкой до двух
часов.

Ручной прогон:

```sh
/root/antizapret/doall.sh
```

Только адреса:

```sh
/root/antizapret/doall.sh ip
```

Только домены:

```sh
/root/antizapret/doall.sh host
```

Частичный прогон не сносит результаты второго типа. IPv6/BGP runtime скачивается
одним срезом commit SHA. Битый или неполный набор не публикуется, старый остаётся
на месте.

## Логи

```sh
journalctl -u antizapret-update.service
journalctl -u antizapret-bgp.service
```

BIRD:

```sh
birdc -s /run/antizapret-bgp/bird.ctl show status
birdc -s /run/antizapret-bgp/bird.ctl show protocols
```

Journald:

- лимит `256M`;
- хранение до `14 дней`.

Для подробных OpenVPN-логов:

- ротация после `8M`;
- до `12` архивов;
- не старше `14 дней`.

Если включены защита от атак и OpenVPN TCP, TLS-сканеры банятся на 24 часа.
Правила цепляются только к реально настроенным OpenVPN TCP-портам.

## Свои списки

Домены:

```text
/root/antizapret/config/include-hosts.txt
/root/antizapret/config/exclude-hosts.txt
```

Сети IPv4 и IPv6:

```text
/root/antizapret/config/include-ips.txt
/root/antizapret/config/exclude-ips.txt
```

После правки:

```sh
/root/antizapret/doall.sh
```

## Ближайшие задачи

1. Убрать зависимость routed prefix от DCO.
2. Догнать матрицу RouterOS/OpenVPN.
3. Добавлять Discord IPv6 только после появления вменяемого источника.
4. Не ломать IPv4 при дальнейшей раскатке IPv6 и BGP.

## Откуда ноги

Основной setup, IPv4-маршрутизация и базовая логика взяты из
[GubernievS/AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN).

Оригинальная схема основана на разработках
[ValdikSS](https://bitbucket.org/anticensority/antizapret-vpn-container/src/master).

Этот форк пилит IPv6, BGP и совместимость поверх исходного проекта.
