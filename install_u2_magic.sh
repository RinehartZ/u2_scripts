#!/usr/bin/env bash
set -euo pipefail

# 可改参数
APP_DIR="${APP_DIR:-/root/u2_scripts}"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/RinehartZ/u2_scripts/refs/heads/main/catch_magic.py}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_NAME="${SERVICE_NAME:-catch-magic}"

VENV_DIR="$APP_DIR/.venv_catch_magic"
REQ_FILE="$APP_DIR/requirements.txt"
ENV_FILE="$APP_DIR/catch_magic.env"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

log() { echo -e "\033[1;32m==>\033[0m $*"; }
err() { echo -e "\033[1;31m!!\033[0m $*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "缺少依赖：$1"; exit 1; }; }

fetch_script() {
  log "确保目录存在: $APP_DIR"
  mkdir -p "$APP_DIR"

  log "下载脚本到 $APP_DIR/catch_magic.py"
  if command -v wget >/dev/null 2>&1; then
    wget -O "$APP_DIR/catch_magic.py" "$SCRIPT_URL"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$APP_DIR/catch_magic.py" "$SCRIPT_URL"
  else
    err "需要 wget 或 curl 其中之一"
    exit 1
  fi
}

write_requirements() {
  log "写入依赖: $REQ_FILE"
  cat > "$REQ_FILE" <<'EOF'
requests>=2.32.2
lxml>=5.2.2
beautifulsoup4>=4.12.3
loguru>=0.7.2
pytz>=2024.1
PyYAML>=6.0.2
EOF
}

ensure_venv() {
  log "创建虚拟环境: $VENV_DIR"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip wheel
  log "安装依赖"
  pip install -r "$REQ_FILE"
}

write_env() {
  log "写入环境文件: $ENV_FILE"
  cat > "$ENV_FILE" <<'EOF'
# qB WebUI 基本配置
QBT_HOST=http://localhost:8080
QBT_USERNAME=admin
QBT_PASSWORD=adminadmin
QBT_FIXED_CATEGORY=keep
QBT_INSECURE=0
QBT_TIMEOUT=30
EOF
}

write_service() {
  log "写入 systemd 服务: $UNIT_FILE"
  cat > "$UNIT_FILE" <<EOF
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
WantedBy=multi-user.target
EOF

  log "启用并启动服务: $SERVICE_NAME"
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
}

main() {
  if [[ $EUID -ne 0 ]]; then
    err "请以 root 运行（用于写入 /etc/systemd/system 和安装到 /root）"
    exit 1
  fi

  need_cmd "$PYTHON_BIN"
  need_cmd systemctl

  fetch_script
  write_requirements
  ensure_venv
  write_env
  write_service

  log "安装完成。后续步骤："
  echo "1) 编辑 $ENV_FILE 填好 qB 登录信息(QBT_HOST/USERNAME/PASSWORD)"
  echo "2) 很重要：编辑 $APP_DIR/catch_magic.py，设置 COOKIES 与必要参数（BK_DIR/WT_DIR 可保持默认或调整）"
  echo "3) 重启服务: systemctl restart $SERVICE_NAME"
  echo "查看日志: journalctl -u $SERVICE_NAME -f"
}

main "$@"
