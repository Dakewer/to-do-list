#!/bin/bash
# user_data: corre una sola vez al primer arranque de la instancia, como root.
# Clona el repo, instala dependencias y deja la app corriendo como servicio systemd.
set -euxo pipefail

dnf install -y git python3-pip unzip

git clone ${repo_url} /opt/todo-list-api
pip3 install -r /opt/todo-list-api/src/requirements.txt

cat > /etc/todo-api.env <<'EOF'
APP_VERSION=${app_version}
AWS_REGION=${region}
AWS_DEFAULT_REGION=${region}
DB_SECRET_NAME=${secret_name}
EOF

cat > /etc/systemd/system/todo-api.service <<'EOF'
[Unit]
Description=to-do-list-api
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/todo-api.env
WorkingDirectory=/opt/todo-list-api/src
ExecStart=/usr/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now todo-api
