#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/jonascool19-pixel/radiobot.git"
REF="${MUSIKBOT187_REF:-main}"
APP="/opt/musikbot187"
DATA="/var/lib/musikbot187"
SERVICE_USER="musikbot187"
ENV_FILE="/etc/musikbot187.env"

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

fail() {
  echo "FEHLER: $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"
command -v apt-get >/dev/null || fail "Ubuntu/Debian mit apt-get erforderlich."
[[ "$(ps -p 1 -o comm= 2>/dev/null || true)" == "systemd" ]] || fail "systemd muss PID 1 sein (Proxmox-CT entsprechend konfigurieren)."

export DEBIAN_FRONTEND=noninteractive
log "Systempakete installieren"
apt-get update
apt-get install -y ca-certificates curl git ffmpeg python3 python3-venv build-essential g++ make gnupg

if ! command -v node >/dev/null || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]]; then
  log "Node.js 22 installieren"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' > /etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y nodejs
fi

if ! command -v yt-dlp >/dev/null; then
  log "yt-dlp installieren"
  python3 -m venv /opt/yt-dlp-venv
  /opt/yt-dlp-venv/bin/pip install --upgrade pip yt-dlp
  ln -sf /opt/yt-dlp-venv/bin/yt-dlp /usr/local/bin/yt-dlp
fi

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
fi

systemctl stop musikbot187.service 2>/dev/null || true
systemctl stop musikbot187-control.service 2>/dev/null || true
rm -rf "$APP"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA" "$DATA/music"

git clone --depth 1 --branch "$REF" "$REPO" "$APP"
cd "$APP/backend"
npm install --omit=dev --no-audit --no-fund
chown -R "$SERVICE_USER:$SERVICE_USER" "$APP"

SETUP_TOKEN="$(node -e 'console.log(require("node:crypto").randomBytes(32).toString("hex"))')"

cat > "$ENV_FILE" <<ENV
NODE_ENV=production
HOST=0.0.0.0
PORT=3000
MUSIKBOT187_DATA_DIR=$DATA
MUSIKBOT187_SETUP_TOKEN=$SETUP_TOKEN
MUSIKBOT187_CONTROL_SOCKET=/run/musikbot187/control.sock
ENV

chown root:"$SERVICE_USER" "$ENV_FILE"
chmod 0640 "$ENV_FILE"

UID_NUM="$(id -u "$SERVICE_USER")"
GID_NUM="$(id -g "$SERVICE_USER")"

cat > /etc/systemd/system/musikbot187-control.service <<UNIT
[Unit]
Description=MusikBot187 privileged control helper
Before=musikbot187.service

[Service]
Type=simple
ExecStart=/usr/bin/node $APP/install/control-daemon.js
Environment=MUSIKBOT187_CONTROL_SOCKET=/run/musikbot187/control.sock
Environment=MUSIKBOT187_UID=$UID_NUM
Environment=MUSIKBOT187_GID=$GID_NUM
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native
RuntimeDirectory=musikbot187
RuntimeDirectoryMode=0750

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/musikbot187.service <<UNIT
[Unit]
Description=MusikBot187 music and radio bot
After=network-online.target musikbot187-control.service
Wants=network-online.target
Requires=musikbot187-control.service

[Service]
Type=simple
WorkingDirectory=$APP/backend
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/node $APP/backend/src/server.js
User=$SERVICE_USER
Group=$SERVICE_USER
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable musikbot187-control.service musikbot187.service
systemctl restart musikbot187-control.service
systemctl restart musikbot187.service
sleep 2

if ! systemctl is-active --quiet musikbot187.service; then
  systemctl --no-pager -l status musikbot187.service || true
  journalctl -u musikbot187.service -n 100 --no-pager || true
  fail "MusikBot187 konnte nicht gestartet werden."
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$IP" ]] || IP='SERVER-IP'
URL="${MUSIKBOT187_PUBLIC_URL:-http://$IP:3000}"

echo
echo '============================================================'
echo 'MusikBot187 3.0.0 erfolgreich installiert'
echo "Dashboard:        ${URL%/}/"
echo "Einrichtungslink: ${URL%/}/#setup=${SETUP_TOKEN}"
echo '============================================================'
echo
echo 'Logs: journalctl -u musikbot187 -f'
