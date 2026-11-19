#!/bin/bash
# Se ejecuta EN la EC2 (como root) desde el workflow de deploy.
# Variables requeridas: URL (zip del release) y TAG (versión, ej. v1.2.0)
set -euo pipefail

curl -fsSL -o /tmp/release.zip "$URL"

rm -rf /opt/todo-list-api
unzip -q /tmp/release.zip -d /opt          # el zip trae el prefijo todo-list-api/
pip3 install -q -r /opt/todo-list-api/src/requirements.txt

sed -i "s/^APP_VERSION=.*/APP_VERSION=${TAG}/" /etc/todo-api.env
systemctl restart todo-api

sleep 5
systemctl is-active todo-api
