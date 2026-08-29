#!/bin/sh
set -eu

if systemctl is-active --quiet admin-antizapret.service; then
    systemctl restart admin-antizapret.service
fi
