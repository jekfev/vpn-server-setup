#!/usr/bin/env bash
set -Eeuo pipefail

# Exit Xray server for a VLESS + REALITY cascade.
# Override before running if the ingress server has another public IPv4:
#   MSK_IP=203.0.113.10 bash install.sh

MSK_IP="${MSK_IP:-}"
DEST_DOMAIN="${DEST_DOMAIN:-www.cloudflare.com}"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
SYSCTL_FILE="/etc/sysctl.d/99-xray-ipv4-only.conf"

log() { printf '\n=== %s ===\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "Запустите скрипт от root: sudo MSK_IP=<ingress-ip> bash install.sh"
[[ -n "$MSK_IP" ]] || die "Укажите публичный IPv4 промежуточного сервера: MSK_IP=<ingress-ip> bash install.sh"
command -v apt-get >/dev/null 2>&1 || die "Скрипт рассчитан на Debian/Ubuntu."

# Basic input validation. UFW receives this value as a source IPv4 address.
if [[ ! "$MSK_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  die "MSK_IP должен быть IPv4-адресом."
fi
IFS=. read -r o1 o2 o3 o4 <<< "$MSK_IP"
for octet in "$o1" "$o2" "$o3" "$o4"; do
  (( 10#$octet <= 255 )) || die "Некорректный IPv4 в MSK_IP: $MSK_IP"
done

[[ "$DEST_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Некорректное имя DEST_DOMAIN."

log "Настройка выходного сервера"
printf 'Разрешенный входящий IP: %s\nREALITY destination: %s\n' "$MSK_IP" "$DEST_DOMAIN"

log "Обновление системы и установка пакетов"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip ufw openssl ca-certificates

log "Отключение IPv6"
cat > "$SYSCTL_FILE" <<'EOF'
# IPv4-only networking for this Xray exit server
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl --system >/dev/null

log "Настройка UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow from "$MSK_IP" to any port 443 proto tcp
ufw --force enable

log "Установка Xray"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

log "Генерация учетных данных"
UUID="$(xray uuid)"
KEYS="$(xray x25519)"
PRIV="$(awk -F ': *' 'tolower($1) ~ /privatekey/ {print $2; exit}' <<< "$KEYS" | tr -d '[:space:]')"
PUB="$(awk -F ': *' 'tolower($1) ~ /^(password|publickey)$/ {print $2; exit}' <<< "$KEYS" | tr -d '[:space:]')"
SHORT="$(openssl rand -hex 8)"

[[ -n "$UUID" && -n "$PRIV" && -n "$PUB" && -n "$SHORT" ]] || die "Не удалось получить UUID или ключи REALITY. Вывод xray x25519:\n$KEYS"

log "Создание конфигурации Xray"
install -d -m 0755 "$(dirname "$XRAY_CONFIG")"
cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "in-exit",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$DEST_DOMAIN:443",
          "serverNames": [
            "$DEST_DOMAIN"
          ],
          "privateKey": "$PRIV",
          "shortIds": [
            "$SHORT"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "finalRules": [
          {
            "action": "block",
            "ip": [
              "geoip:private"
            ]
          },
          {
            "action": "allow"
          }
        ]
      },
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIPv4"
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
chmod 600 "$XRAY_CONFIG"

log "Проверка и запуск Xray"
xray run -test -config "$XRAY_CONFIG"
systemctl enable xray >/dev/null
systemctl restart xray
systemctl --no-pager --full status xray | sed -n '1,12p'

log "Готово"
printf '\nСохраните эти параметры в защищенном месте. Не публикуйте их.\n'
printf 'UUID:      %s\n' "$UUID"
printf 'PublicKey: %s\n' "$PUB"
printf 'ShortId:   %s\n' "$SHORT"
printf '\nВнешний IPv4: '
curl -4fsS --max-time 10 https://ifconfig.co || true
printf '\n\nВход на TCP/443 разрешен только с %s.\n' "$MSK_IP"
