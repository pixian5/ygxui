cat << 'EOF' > /root/step1.sh
#!/bin/bash
set -e

# ================= 基本参数 =================
DEFAULT_MY_SUB="o3"
MY_SUB="${1:-$DEFAULT_MY_SUB}"

DOMAIN="xbz.email"
CF_TOKEN="Wfzj8EiELSTTnKbctM9qTuyv8ga23WTW3W-Lj3KJ"

CERT_BASE="/root/ygkkkca"
KEY_FILE="$CERT_BASE/private.key"
CRT_FILE="$CERT_BASE/cert.crt"

ACME_HOME="$HOME/.acme.sh"
ACME_SH="$ACME_HOME/acme.sh"

# ================= 参数校验 =================
if ! echo "$MY_SUB" | grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}$'; then
  echo "❌ MY_SUB 非法：$MY_SUB"
  exit 1
fi

SUB_DOMAIN="${MY_SUB}.${DOMAIN}"
VX_DOMAIN="${MY_SUB}vx2083.${DOMAIN}"
EMAIL="${MY_SUB}@${DOMAIN}"

ACME_DOM_DIR="$ACME_HOME/${SUB_DOMAIN}_ecc"
ACME_KEY="$ACME_DOM_DIR/${SUB_DOMAIN}.key"
ACME_FULLCHAIN="$ACME_DOM_DIR/fullchain.cer"
ACME_CONF="$ACME_DOM_DIR/${SUB_DOMAIN}.conf"

echo "✅ MY_SUB=$MY_SUB"
echo "✅ SUB_DOMAIN=$SUB_DOMAIN"
echo "✅ VX_DOMAIN=$VX_DOMAIN"
echo

# ================= 工具依赖 =================
ensure_deps() {
  for c in curl jq openssl; do
    command -v $c >/dev/null 2>&1 || need=1
  done
  if [ "${need:-0}" = 1 ]; then
    apt-get update -y
    apt-get install -y curl jq ca-certificates openssl
  fi
}
ensure_deps

# ================= 显示证书信息 =================
show_cert_info() {
  echo "✨ 证书信息（GMT）"
  if [ -s "$CRT_FILE" ]; then
    nb="$(openssl x509 -in "$CRT_FILE" -noout -startdate | cut -d= -f2)"
    na="$(openssl x509 -in "$CRT_FILE" -noout -enddate   | cut -d= -f2)"
    nb_ts="$(date -d "$nb" +%s)"
    na_ts="$(date -d "$na" +%s)"
    echo "✅ 生效时间：$(date -u -d "@$nb_ts" '+%Y-%m-%d %H:%M:%S GMT')"
    echo "✅ 到期时间：$(date -u -d "@$na_ts" '+%Y-%m-%d %H:%M:%S GMT')"
    echo "✅ 剩余天数：$(( (na_ts - $(date +%s)) / 86400 )) 天"
  else
    echo "ℹ️ 目标证书不存在"
  fi

  if [ -s "$ACME_CONF" ]; then
    . "$ACME_CONF"
    [ -n "${Le_NextRenewTime:-}" ] && \
      echo "✅ 下次自动续期：$(date -u -d "@$Le_NextRenewTime" '+%Y-%m-%d %H:%M:%S GMT')"
  fi
  echo
}

# ================= Cloudflare DNS =================
CF_API="https://api.cloudflare.com/client/v4"

get_zone_id() {
  curl -s "$CF_API/zones?name=$DOMAIN&status=active" \
    -H "Authorization: Bearer $CF_TOKEN" \
    | jq -r '.result[0].id'
}

ZONE_ID="$(get_zone_id)"
[ -z "$ZONE_ID" ] && { echo "❌ 获取 ZONE_ID 失败"; exit 1; }

get_ip() {
  curl -s https://api.ip.sb/ip || curl -s https://checkip.amazonaws.com
}
IP="$(get_ip)"
[ -z "$IP" ] && { echo "❌ 获取公网 IP 失败"; exit 1; }

update_dns() {
  local name="$1" proxied="$2"
  rid="$(curl -s "$CF_API/zones/$ZONE_ID/dns_records?name=$name" \
    -H "Authorization: Bearer $CF_TOKEN" | jq -r '.result[0].id')"

  data="$(jq -n \
    --arg type A \
    --arg name "$name" \
    --arg content "$IP" \
    --argjson proxied "$proxied" \
    '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied}')"

  if [ "$rid" != "null" ] && [ -n "$rid" ]; then
    curl -s -X PUT "$CF_API/zones/$ZONE_ID/dns_records/$rid" \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data" >/dev/null
  else
    curl -s -X POST "$CF_API/zones/$ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data" >/dev/null
  fi
}

update_dns "$SUB_DOMAIN" false
update_dns "$VX_DOMAIN" true
echo "✅ DNS 已更新"

# ================= 证书处理 =================
mkdir -p "$CERT_BASE"
chmod 700 "$CERT_BASE"

[ ! -x "$ACME_SH" ] && curl https://get.acme.sh | sh -s email="$EMAIL"
export CF_Token="$CF_TOKEN"

cert_valid() {
  [ -s "$ACME_FULLCHAIN" ] && openssl x509 -in "$ACME_FULLCHAIN" -noout -checkend 0
}

if cert_valid; then
  echo "✅ 使用已有 acme.sh 证书"
else
  echo "ℹ️ 申请新证书"
  "$ACME_SH" --issue --dns dns_cf \
    -d "$SUB_DOMAIN" -d "$VX_DOMAIN" \
    --keylength ec-256 --server letsencrypt
fi

cp -f "$ACME_KEY" "$KEY_FILE"
cp -f "$ACME_FULLCHAIN" "$CRT_FILE"
chmod 600 "$KEY_FILE"
chmod 644 "$CRT_FILE"

# ================= 定时任务 =================
( crontab -l 2>/dev/null | grep -v acme.sh || true
  echo "0 20 * * * TZ=UTC \"$ACME_SH\" --cron --home \"$ACME_HOME\" > /dev/null"
) | crontab -

echo "✅ 已启用 acme.sh 自动续期（UTC 20:00）"
echo

show_cert_info
EOF

chmod +x /root/step1.sh