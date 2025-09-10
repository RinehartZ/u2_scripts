#!/usr/bin/env bash
set -euo pipefail

# One-click installer for u2_magic.py as a systemd service with Python venv
# Usage:
#   sudo ./install_u2_magic_service.sh [--python /usr/bin/python3] [--user youruser] [--name u2-magic]

SERVICE_NAME="u2-magic"
RUN_USER="$(logname 2>/dev/null || echo ${SUDO_USER:-${USER}})"
PYTHON_BIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python)
      PYTHON_BIN="$2"; shift 2;;
    --user)
      RUN_USER="$2"; shift 2;;
    --name)
      SERVICE_NAME="$2"; shift 2;;
    *)
      echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

WORKDIR="/workspace"
SCRIPT_PATH="$WORKDIR/u2_magic.py"
if [[ ! -f "$SCRIPT_PATH" ]]; then
  echo "u2_magic.py not found at $SCRIPT_PATH" >&2
  exit 1
fi

# Choose python
if [[ -z "$PYTHON_BIN" ]]; then
  for cand in /usr/bin/python3.11 /usr/local/bin/python3.11 /usr/bin/python3 /usr/local/bin/python3; do
    if [[ -x "$cand" ]]; then PYTHON_BIN="$cand"; break; fi
  done
fi
if [[ -z "$PYTHON_BIN" ]]; then
  echo "Python3 not found. Install Python 3.11+ first." >&2
  exit 1
fi

VENVDIR="$WORKDIR/.venv_u2_magic"
sudo -u "$RUN_USER" bash -c "cd $WORKDIR && $PYTHON_BIN -m venv $VENVDIR"

# Upgrade pip and install deps
REQ_PKGS=(
  requests bs4 lxml deluge-client loguru func-timeout pytz nest_asyncio aiohttp paramiko qbittorrent-api
)
sudo -u "$RUN_USER" bash -c "$VENVDIR/bin/pip install --upgrade pip wheel setuptools"
sudo -u "$RUN_USER" bash -c "$VENVDIR/bin/pip install ${REQ_PKGS[*]}"

# Create a wrapper
WRAPPER="$WORKDIR/run_u2_magic.sh"
cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /workspace
exec /workspace/.venv_u2_magic/bin/python /workspace/u2_magic.py
EOF
chown "$RUN_USER":"$RUN_USER" "$WRAPPER"
chmod +x "$WRAPPER"

# Prepare systemd unit
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=U2 Magic Service (u2_magic.py)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${WORKDIR}
ExecStart=${WRAPPER}
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "Installed and started service: $SERVICE_NAME"
echo "Logs: journalctl -u $SERVICE_NAME -f | cat"
