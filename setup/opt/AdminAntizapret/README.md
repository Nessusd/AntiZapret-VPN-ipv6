# AdminAntizapret

Веб-панель встроена в AntiZapret-VPN-ipv6 и устанавливается только единым `setup.sh` родительского проекта.

- Код панели размещается в `/opt/AdminAntizapret`.
- Общие параметры AntiZapret читаются из `/root/antizapret/setup`.
- База данных, `.env`, журналы, резервные копии и другие runtime-данные не входят в Git.
- Локальный менеджер `/root/AdminPanel/adminpanel.sh` предназначен для обслуживания уже установленной панели.

Отдельная установка панели не поддерживается.

Исходная основа панели: [Kirito0098/AdminAntizapret](https://github.com/Kirito0098/AdminAntizapret), лицензия MIT.
