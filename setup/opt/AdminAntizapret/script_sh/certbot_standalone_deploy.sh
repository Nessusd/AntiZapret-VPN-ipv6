#!/bin/sh
set -eu

# После успешного обновления сертификата web-процесс должен перечитать его с диска.
if systemctl is-active --quiet admin-antizapret.service; then
    systemctl restart admin-antizapret.service
fi
