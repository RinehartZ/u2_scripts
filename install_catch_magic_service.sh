#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/workspace}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-$APP_DIR/.venv_catch_magic}"
REQ_FILE="${REQ_FILE:-$APP_DIR/catch_magic_requirements.txt}"
SERVICE_NAME="${SERVICE_NAME:-catch-magic}"
USER_MODE="${USER_MODE:-auto}"   # auto|system|user
RUN_USER="${RUN_USER:-qbittorrent}"  # used for system mode when running as root
ENV_FILE="${ENV_FILE:-$APP_DIR/catch_magic.env}"

write_env_template() {
  cat > "$ENV_FILE" <<EOT
# qB WebUI
QBT_HOST=http://localhost:8080
QBT_USERNAME=admin
QBT_PASSWORD=adminadmin
QBT_FIXED_CATEGORY=keep
# trust self-signed
QBT_INSECURE=0
# wait seconds for torrent to appear
QBT_TIMEOUT=30
EOT
}

ensure_venv() {
  if [[ ! -d "$VENV_DIR" ]]; then
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip wheel
  pip install -r "$REQ_FILE"
}

install_systemd() {
  local mode="$1"
  local unit_file
  if [[ "$mode" == "user" ]]; then
    unit_file="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
    mkdir -p "$(dirname "$unit_file")"
  else
    unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
  fi

  [[ -f "$ENV_FILE" ]] || write_env_template

  cat > "$unit_file" <<UNIT
[Unit]
Description=Catch U2 Magic and add to qBittorrent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/catch_magic.py
Restart=always
RestartSec=5s

[Install]
WantedBy=$( [[ "$mode" == "user" ]] && echo default.target || echo multi-user.target )
UNIT

  if [[ "$mode" == "user" ]]; then
    systemctl --user daemon-reload
    systemctl --user enable --now "$SERVICE_NAME"
  else
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
  fi
}

main() {
  local mode="$USER_MODE"
  if [[ "$mode" == "auto" ]]; then
    if [[ $EUID -eq 0 ]]; then
      mode="system"
    else
      mode="user"
    fi
  fi

  ensure_venv
  install_systemd "$mode"

  echo "Installed and started service '${SERVICE_NAME}' in $mode mode."
  echo "Edit env at: $ENV_FILE"
}

main "$@"
