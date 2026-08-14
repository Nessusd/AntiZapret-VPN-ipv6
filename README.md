# AntiZapret VPN IPv6

Этот репозиторий — форк
[AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN). Его основная
задача — добавить нормальную поддержку IPv6 и при этом сохранить привычную
работу проекта по IPv4.

## Текущее состояние

IPv6 уже работает в OpenVPN, WireGuard и AmneziaWG. Клиент получает адреса обоих
стеков, домены с AAAA-записями направляются через AntiZapret, а для полного VPN
добавлена маршрутизация всего IPv6-трафика. На сервере используются отдельные
правила `ip6tables`, наборы `ipset` и NAT66.

Списки IPv6 хранятся рядом с обычными IPv4-списками в файлах `*-ips6.txt` и
обновляются тем же системным таймером. Сейчас опубликованы списки Cloudflare,
Amazon, Google, Telegram, Hetzner, DigitalOcean, OVH, Meta/WhatsApp, Roblox и
Akamai. Для Discord подходящего надёжного источника IPv6-префиксов пока нет.

Существующие конфигурации OpenVPN и WireGuard переводятся в режим IPv4+IPv6 без
смены IPv4-адресов и ключей. Если IPv6 не нужен, его можно отключить при
установке — старый IPv4-режим останется прежним. Обратная совместимость с
оригинальным проектом считается обязательной для всех дальнейших изменений.

Для клиентских маршрутизаторов добавлена необязательная передача списков по BGP.
Она работает через отдельный экземпляр BIRD 2, не импортирует маршруты от
клиентов и не записывает свои таблицы в FIB сервера. По умолчанию BGP выключен,
а все старые и новые клиенты продолжают получать статические маршруты.

## Известные ограничения

MikroTik RouterOS 7.19.6 получает IPv6-адрес OpenVPN-туннеля, но сохраняет только
последний из нескольких параметров `route-ipv6`. Поэтому служебный маршрут для
доменов работает, а передать таким способом весь список IPv6-сетей нельзя.
Большой набор параметров также может вызвать сообщение
`received OVPN option length exceeds limit` и повторное подключение.

OpenVPN-клиенту, работающему как маршрутизатор, можно назначить отдельный
глобальный префикс от `/48` до `/64`. Этот режим ещё проверен не во всех
вариантах; автоматическая установка серверного маршрута сейчас зависит от
OpenVPN DCO.

BGP на стороне клиента автоматически не настраивается. Команды ниже проверены
на RouterOS 7.19.6 и 7.23.1, но работу маршрутизации на конкретном роутере всё равно
нужно проверить отдельно.

Для выхода клиентов в IPv6-интернет серверу нужен собственный глобальный
IPv6-адрес и маршрут по умолчанию. Внутреннего ULA-адреса туннеля для этого
недостаточно.

## Что дальше

В ближайших планах:

1. Проверить обновление старых IPv4-установок и закрепить работу IPv6 на обычных
   клиентах OpenVPN, WireGuard и AmneziaWG.
2. Разобраться с ограничениями RouterOS и проверить маршрутизацию префикса за
   OpenVPN-клиентом с DCO и без него.
3. Продолжить работу над IPv6-списками, добавляя новые источники только после их
   проверки.
4. Проверить BGP на физическом RouterOS-маршрутизаторе и закрепить
   поведение после обновлений RouterOS.

## Установка

Нужен отдельный сервер или VPS с Ubuntu 24.04 либо Debian 13 или новее, внешним
IPv4-адресом, 1 ГБ памяти и примерно 10 ГБ свободного места. Для полноценного
IPv6 потребуется также глобальный IPv6-адрес.

Установка и обновление выполняются от `root`:

```sh
bash <(wget -qO- --no-hsts --inet4-only \
  https://raw.githubusercontent.com/Nessusd/AntiZapret-VPN-ipv6/main/setup.sh)
```

Чтобы включить IPv6, оставьте `n` в ответе на вопрос
`Disable IPv6 on this server?`.

Вопрос `Enable private BGP route delivery for router clients?` включает BIRD и
серверную передачу маршрутов. Ответ `n` не устанавливает BIRD, не создаёт BGP-
службу и не открывает TCP/179. При включении установщик предлагает частные ASN;
по умолчанию используются `4200000290` на сервере и `4200000291` на клиентах.

Установщик меняет сетевые настройки и правила межсетевого экрана, а также
удаляет UFW, Firewalld, AppArmor и ряд ненужных для VPN пакетов. Его лучше
запускать на отдельной машине, предварительно просмотрев `setup.sh` и сделав
резервную копию.

Перед повторной установкой можно создать встроенную резервную копию:

```sh
/root/antizapret/client.sh 8
```

## После установки

Клиентами управляет команда:

```sh
/root/antizapret/client.sh
```

Если BGP включён глобально, при создании клиента можно выбрать режим `static`
или `bgp`. Первый режим полностью повторяет прежнее поведение. Во втором
OpenVPN не получает большой набор маршрутов через CCD, а профиль WireGuard
использует `AllowedIPs = 0.0.0.0/0, ::/0` и `Table = off`; маршруты в системе
клиента должен устанавливать его BGP-демон.

BGP-соседство устанавливается по IPv4 внутри туннеля: сервер слушает
`10.29.0.1` для OpenVPN UDP, `10.29.4.1` для OpenVPN TCP и `10.29.8.1` для
WireGuard. При альтернативном диапазоне первый октет меняется на `172`.
TCP/179 с публичного интерфейса закрыт. Сервер передаёт IPv4 и IPv6 одним
сеансом, не принимает клиентские маршруты и помечает анонсы large community
`(ASN сервера, 29, 4)` или `(ASN сервера, 29, 6)`.

На клиентском маршрутизаторе нужно создать исходящий eBGP-сеанс к
соответствующему адресу сервера, указать клиентский ASN как local AS, серверный
ASN как remote AS и включить IPv4/IPv6 AFI. Экспорт в сторону сервера следует
запретить, а на импорт поставить фильтр и ограничение числа префиксов.

### RouterOS 7

Сначала создайте клиента в режиме `bgp`, подключите VPN и посмотрите его
IPv4-адрес:

```routeros
/ip/address/print detail where interface="AZ-veesp.com"
```

В командах ниже нужно изменить:

- `10.29.0.2` — адрес самого роутера в VPN;
- `10.29.0.1` — адрес сервера: `10.29.0.1` для OpenVPN UDP,
  `10.29.4.1` для OpenVPN TCP и `10.29.8.1` для WireGuard; при
  альтернативном диапазоне `10` заменяется на `172`;
- `4200000290` и `4200000291` — ASN сервера и клиента, если при установке
  выбирались другие;
- `main` — таблица, куда будут помещены маршруты. Для policy routing её можно
  заменить на заранее созданную таблицу.

Общие для всех RouterOS 7 фильтры принимают только анонсы AntiZapret нужного
стека. Обратный экспорт полностью запрещён:

```routeros
/routing/filter/rule
add chain=antizapret-bgp-in rule="if (afi ipv4 && bgp-input-remote-as == 4200000290 && bgp-large-communities includes 4200000290:29:4) { accept; }"
add chain=antizapret-bgp-in rule="if (afi ipv6 && bgp-input-remote-as == 4200000290 && bgp-large-communities includes 4200000290:29:6) { accept; }"
add chain=antizapret-bgp-in rule="reject;"
add chain=antizapret-bgp-out rule="reject;"
```

Для RouterOS 7.19 соединение создаётся так:

```routeros
/routing/bgp/connection
add name=antizapret-bgp as=4200000291 local.address=10.29.0.2 local.role=ebgp remote.address=10.29.0.1/32 remote.as=4200000290 afi=ip,ipv6 routing-table=main connect=yes listen=no input.filter=antizapret-bgp-in input.limit-process-routes-ipv4=10000 input.limit-process-routes-ipv6=10000 output.filter-chain=antizapret-bgp-out
```

На RouterOS 7.20 и новее сначала нужно создать отдельный BGP instance:

```routeros
/routing/bgp/instance
add name=antizapret-bgp as=4200000291

/routing/bgp/connection
add name=antizapret-bgp instance=antizapret-bgp local.address=10.29.0.2 local.role=ebgp remote.address=10.29.0.1/32 remote.as=4200000290 afi=ip,ipv6 routing-table=main connect=yes listen=no input.filter=antizapret-bgp-in input.limit-process-routes-ipv4=10000 input.limit-process-routes-ipv6=10000 output.filter-chain=antizapret-bgp-out
```

Состояние сеанса и принятые маршруты проверяются командами:

```routeros
/routing/bgp/session/print detail where name~"antizapret-bgp"
/ip/route/print count-only where protocol=bgp
/ipv6/route/print count-only where protocol=bgp
```

Повторно эти команды выполнять нельзя: они создают новые записи. Для пересоздания
сначала удалите только объекты AntiZapret:

```routeros
/routing/bgp/connection/remove [find where name="antizapret-bgp"]
/routing/bgp/instance/remove [find where name="antizapret-bgp"]
/routing/filter/rule/remove [find where chain="antizapret-bgp-in"]
/routing/filter/rule/remove [find where chain="antizapret-bgp-out"]
```

Готовые профили находятся в каталогах:

```text
/root/antizapret/client/openvpn/
/root/antizapret/client/wireguard/
/root/antizapret/client/amneziawg/
```

Списки обновляются каждый день между 02:00 и 04:00 по времени сервера. Запустить
обновление вручную можно так:

```sh
/root/antizapret/doall.sh
```

Свои домены добавляются в `/root/antizapret/config/include-hosts.txt`, а сети
IPv4 и IPv6 — в `/root/antizapret/config/include-ips.txt`. Для исключений рядом
лежат `exclude-hosts.txt` и `exclude-ips.txt`. После изменения этих файлов нужно
снова выполнить `doall.sh`.

## Происхождение проекта

Установщик, IPv4-маршрутизация и основная логика взяты из
[GubernievS/AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN).
Оригинальный проект основан на разработках
[ValdikSS](https://bitbucket.org/anticensority/antizapret-vpn-container/src/master).
Изменения этого форка, связанные с IPv6, разрабатываются и тестируются отдельно.
