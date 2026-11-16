#!/usr/bin/env bash
# Универсальная установка: sysctl/BBR + dnsproxy + Caddy (layer4) + опционально Marzban node
# Поддержка: Debian 11/12/13, Ubuntu 20.04/22.04/24.04, amd64/arm64
#
# Неинтерактивный запуск:
#   INSTALL_NODE=yes|no  — ставить ли Marzban node без вопроса
#   SKIP_EDITOR=1        — не открывать редактор для caddy.json
set -euo pipefail

log()  { echo -e "\n=== $* ==="; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# Есть ли интерактивный терминал (работает и при запуске через curl | bash)
HAS_TTY=0
if [ -r /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then HAS_TTY=1; fi

ask_yes_no() {  # ask_yes_no "Вопрос" default(y/n)
  local q="$1" def="${2:-n}" ans hint="[y/N]"
  [ "$def" = "y" ] && hint="[Y/n]"
  if [ "$HAS_TTY" -eq 0 ]; then [ "$def" = "y" ]; return; fi
  while true; do
    read -r -p "$q $hint: " ans </dev/tty || ans=""
    ans="${ans:-$def}"
    case "${ans,,}" in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
      *) echo "Ответь y или n" ;;
    esac
  done
}

echo "=== $(date) Начало установки ==="

# ---------- Проверки ----------
[ "$(id -u)" -eq 0 ] || die "Запустите скрипт от root (su -) или через sudo"

[ -r /etc/os-release ] || die "Не найден /etc/os-release"
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) [[ "${ID_LIKE:-}" == *debian* ]] || die "Поддерживаются только Debian/Ubuntu (обнаружено: ${PRETTY_NAME:-unknown})" ;;
esac
echo "ОС: ${PRETTY_NAME:-$ID}"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *) die "Неподдерживаемая архитектура: $ARCH" ;;
esac
echo "Архитектура: $ARCH"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # Ubuntu: не спрашивать про перезапуск сервисов

# ---------- Пакеты ----------
log "Обновление системы"
apt-get update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

log "Установка необходимых пакетов"
apt-get install -y sudo curl wget tar git ca-certificates libcap2-bin supervisor iproute2 kmod procps

# ---------- sysctl ----------
log "Настройка sysctl"
cat >/etc/sysctl.d/80-router.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.proxy_arp = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_all = 1
EOF

cat >/etc/sysctl.d/90-tune.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF

# /etc/sysctl.conf применяется последним (Debian ≤12, Ubuntu) и может перекрыть наши значения —
# комментируем в нём те же ключи (например, остатки от старой версии скрипта)
if [ -f /etc/sysctl.conf ]; then
  cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)"
  for key in $(cat /etc/sysctl.d/80-router.conf /etc/sysctl.d/90-tune.conf | cut -d= -f1 | tr -d ' '); do
    sed -i -E "s|^[[:space:]]*(${key//./\\.})[[:space:]]*=|# \1 =|" /etc/sysctl.conf
  done
fi

modprobe tcp_bbr || warn "Не удалось загрузить tcp_bbr (возможно, встроен в ядро или это контейнер)"
echo tcp_bbr > /etc/modules-load.d/bbr.conf
sysctl --system >/dev/null || warn "Часть параметров sysctl не применилась (в OpenVZ/LXC это нормально)"
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc || true

# ---------- dnsproxy ----------
log "Загрузка и установка dnsproxy"
VERSION="$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/AdguardTeam/dnsproxy/releases/latest)")"
[[ "$VERSION" == v* ]] || die "Не удалось определить версию dnsproxy"
echo "Latest AdguardTeam dnsproxy version is $VERSION"

TMP="$(mktemp -d)"
wget -qO "$TMP/dnsproxy.tar.gz" "https://github.com/AdguardTeam/dnsproxy/releases/download/${VERSION}/dnsproxy-linux-${ARCH}-${VERSION}.tar.gz"
tar -xzf "$TMP/dnsproxy.tar.gz" -C "$TMP"
install -m 755 "$TMP/linux-${ARCH}/dnsproxy" /usr/bin/dnsproxy
rm -rf "$TMP"

log "Освобождение порта 53"
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  systemctl disable --now systemd-resolved
  ok "systemd-resolved отключён"
fi

log "Настройка supervisor для dnsproxy"
cat >/etc/supervisor/conf.d/dnsproxy.conf <<'EOL'
[program:dnsproxy]
command = /usr/bin/dnsproxy -l 127.0.0.1 -p 53 -u https://dns.marss.vip/dns-query -b 195.63.166.174:53
user = root
autostart = true
autorestart = true
stdout_logfile = /var/log/supervisor/dnsproxy.log
stderr_logfile = /var/log/supervisor/dnsproxy.error.log
environment = LANG="en_US.UTF-8"
EOL

systemctl enable supervisor >/dev/null 2>&1 || true
systemctl restart supervisor
sleep 2
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true
supervisorctl restart dnsproxy >/dev/null 2>&1 || true

log "Ожидание запуска dnsproxy"
for _ in {1..15}; do
  ss -lnu | grep -q '127.0.0.1:53 ' && break
  sleep 1
done
if ss -lnu | grep -q '127.0.0.1:53 '; then
  ok "dnsproxy слушает 127.0.0.1:53"
else
  tail -n 20 /var/log/supervisor/dnsproxy.error.log 2>/dev/null || true
  die "dnsproxy НЕ слушает порт 53 — resolv.conf не изменён"
fi

log "Настройка /etc/resolv.conf"
cp -aL /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf   # может быть симлинком на systemd-resolved
echo "nameserver 127.0.0.1" > /etc/resolv.conf

if getent hosts github.com >/dev/null; then
  ok "DNS через dnsproxy работает"
else
  [ -f /etc/resolv.conf.bak ] && cp -a /etc/resolv.conf.bak /etc/resolv.conf
  die "DNS через dnsproxy не резолвит — старый resolv.conf восстановлен"
fi

# Чтобы resolv.conf не перезаписывали сетевые менеджеры
if [ -f /etc/dhcp/dhclient.conf ] && ! grep -q '^supersede domain-name-servers 127.0.0.1;' /etc/dhcp/dhclient.conf; then
  echo 'supersede domain-name-servers 127.0.0.1;' >> /etc/dhcp/dhclient.conf
  ok "dhclient: DNS зафиксирован"
fi
if [ -d /etc/NetworkManager/conf.d ]; then
  printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/90-dns-none.conf
  systemctl reload NetworkManager 2>/dev/null || true
  ok "NetworkManager: управление DNS отключено"
fi
if command -v resolvconf >/dev/null 2>&1 && [ -d /etc/resolvconf ]; then
  warn "Установлен resolvconf — он может перезаписать /etc/resolv.conf. При проблемах: apt purge resolvconf"
fi

systemctl is-active --quiet supervisor && ok "supervisor активен" || warn "supervisor не запущен"

# ---------- Caddy + layer4 ----------
log "Установка Go"
GO_VER="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
[[ "$GO_VER" == go* ]] || die "Не удалось определить версию Go"
echo "Go version: $GO_VER"
curl -fsSL "https://go.dev/dl/${GO_VER}.linux-${ARCH}.tar.gz" -o /tmp/go.tgz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tgz
rm -f /tmp/go.tgz
export PATH="/usr/local/go/bin:${PATH}"
export GOTOOLCHAIN=local

log "Сборка Caddy с layer4 (xcaddy)"
BUILD_DIR="$(mktemp -d)"
cd "$BUILD_DIR"
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
"$(go env GOPATH)/bin/xcaddy" build --with github.com/mholt/caddy-l4

systemctl stop caddy 2>/dev/null || true
install -m 755 ./caddy /usr/bin/caddy
setcap cap_net_bind_service=+ep /usr/bin/caddy
cd /
rm -rf "$BUILD_DIR"

log "Проверка версии и наличия модуля layer4"
caddy version
caddy list-modules | grep -i layer4 || die "Модуль layer4 не найден"

log "Создание /etc/caddy и systemd unit"
mkdir -p /etc/caddy/
cat >/etc/systemd/system/caddy.service <<'EOF'
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

if [[ ! -f /etc/caddy/caddy.json ]]; then
  cat >/etc/caddy/caddy.json <<'JSON'
{
  "apps": {
    "layer4": {
      "servers": {}
    }
  }
}
JSON
fi

EDITOR_BIN="${EDITOR:-}"
if [[ -z "$EDITOR_BIN" ]]; then
  if command -v nano &>/dev/null; then EDITOR_BIN="nano"; else EDITOR_BIN="vi"; fi
fi

if [ "$HAS_TTY" -eq 1 ] && [ "${SKIP_EDITOR:-0}" != "1" ]; then
  echo
  echo "======================== ВНИМАНИЕ ========================"
  echo "Сейчас откроется /etc/caddy/caddy.json в редакторе: ${EDITOR_BIN}"
  echo "Вставь свой конфиг, сохрани файл и выйди из редактора."
  echo "=========================================================="
  read -r -p "Нажми Enter, чтобы открыть редактор..." </dev/tty || true
  "$EDITOR_BIN" /etc/caddy/caddy.json </dev/tty >/dev/tty
else
  warn "Редактор пропущен — отредактируй /etc/caddy/caddy.json вручную и выполни: systemctl restart caddy"
fi

log "Проверка конфига Caddy"
systemctl daemon-reload
systemctl enable caddy.service >/dev/null 2>&1
if caddy validate --config /etc/caddy/caddy.json; then
  systemctl restart caddy
  systemctl is-active --quiet caddy && ok "Caddy запущен" || warn "Caddy не запустился: journalctl -u caddy -n 50"
else
  warn "Ошибка в /etc/caddy/caddy.json — Caddy не запущен. Исправь и выполни: systemctl restart caddy"
fi
systemctl status caddy --no-pager -l || true

# ---------- Marzban node ----------
log "Marzban node"
INSTALL_NODE="${INSTALL_NODE:-}"
if [ -z "$INSTALL_NODE" ]; then
  if [ "$HAS_TTY" -eq 1 ]; then
    if ask_yes_no "Установить Marzban node?" n; then INSTALL_NODE=yes; else INSTALL_NODE=no; fi
  else
    warn "Нет терминала и INSTALL_NODE не задан — нода не устанавливается"
    INSTALL_NODE=no
  fi
fi

if [[ "${INSTALL_NODE,,}" =~ ^(y|yes|1|true|да)$ ]]; then
  bash -c "$(curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban-node.sh)" @ install
else
  echo "Установка ноды пропущена. Поставить позже:"
  echo '  sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban-node.sh)" @ install'
fi

log "Готово"
echo "BBR:      $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
echo "qdisc:    $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
echo "dnsproxy: $(supervisorctl status dnsproxy 2>/dev/null | awk '{print $2}' || echo '?')"
echo "caddy:    $(systemctl is-active caddy 2>/dev/null || true)"
