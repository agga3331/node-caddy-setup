#!/usr/bin/env bash
set -euo pipefail

echo "=== $(date) Начало установки ==="

# проверка root
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Запустите скрипт от root (su -) или через sudo"
  exit 1
fi

echo "=== Обновление системы ==="
apt update -y
apt upgrade -y

echo "=== Проверка наличия sudo ==="
if ! command -v sudo &>/dev/null; then
  echo "=== sudo не найден, устанавливаю... ==="
  apt install -y sudo
else
  echo "=== sudo уже установлен ==="
fi

echo "=== Установка необходимых пакетов ==="
apt install -y curl wget tar supervisor net-tools

echo "=== Настройка sysctl.conf ==="
tee /etc/sysctl.conf > /dev/null <<'EOL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.proxy_arp = 0
net.ipv4.conf.default.send_redirects = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_all = 1
EOL

sysctl -p

echo "=== Загрузка и установка dnsproxy ==="
VERSION=$(curl -s https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest | grep tag_name | cut -d '"' -f 4) && echo "Latest AdguardTeam dnsproxy version is $VERSION"
wget -O dnsproxy.tar.gz "https://github.com/AdguardTeam/dnsproxy/releases/download/${VERSION}/dnsproxy-linux-amd64-${VERSION}.tar.gz"
tar -xzvf dnsproxy.tar.gz
cd linux-amd64
sudo mv dnsproxy /usr/bin/dnsproxy
cd ..
rm -rf linux-amd64 dnsproxy.tar.gz

echo "=== Настройка supervisor для dnsproxy ==="
tee /etc/supervisor/conf.d/dnsproxy.conf > /dev/null <<EOL
[program:dnsproxy]
command = /usr/bin/dnsproxy -l 127.0.0.1 -p 53 -u https://doht.marss.vip/dns-query -b 91.84.123.216:53
user = root
autostart = true
autorestart = true
stdout_logfile = /var/log/supervisor/dnsproxy.log
stderr_logfile = /var/log/supervisor/dnsproxy.error.log
environment = LANG="en_US.UTF-8"
EOL

systemctl restart supervisor

echo "=== Тестовый запуск dnsproxy (в фоне) ==="
dnsproxy -l 127.0.0.1 -p 53 -u https://doht.marss.vip/dns-query -b 91.84.123.216:53 &

echo "=== Настройка /etc/resolv.conf ==="
tee /etc/resolv.conf > /dev/null <<EOL
nameserver 127.0.0.1
EOL

echo "=== Проверка статуса сервисов ==="
# проверка dnsproxy на 53 порту
if netstat -tuln | grep -q ":53 "; then
  echo "✅ dnsproxy слушает порт 53"
else
  echo "❌ dnsproxy НЕ слушает порт 53"
fi

# проверка supervisor
if systemctl is-active --quiet supervisor; then
  echo "✅ supervisor активен"
else
  echo "❌ supervisor не запущен"
fi

echo "=== Сборка Caddy с layer4 (xcaddy) и установка ==="
apt update -y
apt install -y curl git ca-certificates libcap2-bin

# Установка Go
curl -fsSL https://go.dev/dl/go1.22.7.linux-amd64.tar.gz -o /tmp/go.tgz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tgz
rm -f /tmp/go.tgz

export PATH="/usr/local/go/bin:${PATH}"

# Установка xcaddy и сборка Caddy с layer4
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
"$(go env GOPATH)/bin/xcaddy" build --with github.com/mholt/caddy-l4

# Установка бинарника
mv -f ./caddy /usr/bin/caddy
setcap cap_net_bind_service=+ep /usr/bin/caddy

echo "=== Проверка версии и наличия модуля layer4 ==="
caddy version
caddy list-modules | grep -i layer4

echo "=== Создание директории /etc/caddy/ ==="
mkdir -p /etc/caddy/

echo "=== Создание systemd unit для Caddy ==="
tee /etc/systemd/system/caddy.service > /dev/null <<'EOF'
[Unit]
Description=Caddy L4 Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/caddy run --config /etc/caddy/caddy.json
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy.json
Restart=on-failure
LimitNOFILE=1048576
User=root
Group=root
WorkingDirectory=/etc/caddy

[Install]
WantedBy=multi-user.target
EOF

echo "=== Создание /etc/caddy/caddy.json и открытие для ручного редактирования ==="
if [[ ! -f /etc/caddy/caddy.json ]]; then
  tee /etc/caddy/caddy.json > /dev/null <<'JSON'
{
  "apps": {
    "layer4": {
      "servers": {}
    }
  }
}
JSON
fi

# Выбор редактора
EDITOR_BIN="${EDITOR:-}"
if [[ -z "${EDITOR_BIN}" ]]; then
  if command -v nano &>/dev/null; then
    EDITOR_BIN="nano"
  else
    EDITOR_BIN="vi"
  fi
fi

echo
echo "======================== ВНИМАНИЕ ========================"
echo "Сейчас откроется /etc/caddy/caddy.json в редакторе: ${EDITOR_BIN}"
echo "Вставь свой конфиг, сохрани файл и выйди из редактора."
echo "После выхода скрипт продолжит выполнение."
echo "=========================================================="
echo

"${EDITOR_BIN}" /etc/caddy/caddy.json

echo "=== Обновление systemd и запуск Caddy ==="
systemctl daemon-reload
systemctl enable --now caddy.service
systemctl restart caddy

echo "=== Статус Caddy ==="
systemctl status caddy --no-pager
