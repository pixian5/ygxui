cat << 'STEP1_EOF' > /root/step1.sh
#!/bin/bash
set -e

# ===== 生成器传参：第1个参数就是子域前缀 =====
DEFAULT_MY_SUB="o3"
MY_SUB="${1:-$DEFAULT_MY_SUB}"

# 校验
if ! echo "$MY_SUB" | grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}$'; then
  echo "❌ MY_SUB 非法：只能是字母/数字/短横线，且长度 1~62，且不能以 - 开头"
  echo "   当前：$MY_SUB"
  exit 1
fi

echo "✅ 生成器收到参数：MY_SUB=$MY_SUB"
echo "✅ 将生成并执行：/root/cf_dns_and_acme_cert.sh"
echo

# ===== 生成真正的业务脚本（这里不能用单引号 heredoc，否则 MY_SUB 不会注入）=====
cat << CFACME_EOF > /root/cf_dns_and_acme_cert.sh
#!/bin/bash
set -e

# ================= 配置变量区（默认值） =================
MY_SUB="${MY_SUB}"
DOMAIN="xbz.email"
CF_TOKEN="Wfzj8EiELSTTnKbctM9qTuyv8ga23WTW3W-Lj3KJ"

CERT_BASE="/root/ygkkkca"
KEY_FILE="\$CERT_BASE/private.key"
CRT_FILE="\$CERT_BASE/cert.crt"
# =======================================================

# ---------- 依赖 MY_SUB 的派生变量 ----------
SUB_DOMAIN="\${MY_SUB}.\${DOMAIN}"
VX_DOMAIN="\${MY_SUB}vx2083.\${DOMAIN}"
EMAIL="\${MY_SUB}@\$DOMAIN"

ACME_HOME="\$HOME/.acme.sh"
ACME_SH="\$ACME_HOME/acme.sh"
ACME_DOM_DIR="\$ACME_HOME/\${SUB_DOMAIN}_ecc"
ACME_KEY="\$ACME_DOM_DIR/\${SUB_DOMAIN}.key"
ACME_FULLCHAIN="\$ACME_DOM_DIR/fullchain.cer"
ACME_CONF="\$ACME_DOM_DIR/\${SUB_DOMAIN}.conf"

echo "✅ 当前 MY_SUB=\$MY_SUB"
echo "✅ SUB_DOMAIN=\$SUB_DOMAIN"
echo "✅ VX_DOMAIN=\$VX_DOMAIN"
echo

# ===== 显示证书有效期 / 续期信息（统一 GMT 格式：YYYY-MM-DD HH:MM:SS GMT）=====
show_cert_info() {
  echo "✨ 证书有效期 / 续期信息"

  if [ -s "\$CRT_FILE" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
      echo "ℹ️ 未安装 openssl，正在安装..."
      apt-get update -y >/dev/null
      apt-get install -y openssl >/dev/null
    fi

    local nb_raw na_raw nb_ts na_ts now_ts days_left

    nb_raw="\$(openssl x509 -in "\$CRT_FILE" -noout -startdate 2>/dev/null | sed 's/^notBefore=//')"
    na_raw="\$(openssl x509 -in "\$CRT_FILE" -noout -enddate   2>/dev/null | sed 's/^notAfter=//')"

    if [ -n "\$nb_raw" ]; then
      nb_ts="\$(date -d "\$nb_raw" +%s 2>/dev/null || true)"
      if [ -n "\$nb_ts" ]; then
        echo "✅ 生效时间：\$(date -u -d "@\$nb_ts" '+%Y-%m-%d %H:%M:%S GMT')"
      else
        echo "✅ 生效时间：\$nb_raw"
      fi
    else
      echo "⚠️ 无法读取证书生效时间"
    fi

    if [ -n "\$na_raw" ]; then
      na_ts="\$(date -d "\$na_raw" +%s 2>/dev/null || true)"
      if [ -n "\$na_ts" ]; then
        echo "✅ 到期时间：\$(date -u -d "@\$na_ts" '+%Y-%m-%d %H:%M:%S GMT')"
        now_ts="\$(date +%s)"
        days_left=\$(( (na_ts - now_ts) / 86400 ))
        echo "✅ 剩余天数：约 \${days_left} 天"
      else
        echo "✅ 到期时间：\$na_raw"
      fi
    else
      echo "⚠️ 无法读取证书到期时间"
    fi
  else
    echo "ℹ️ 目标证书不存在：\$CRT_FILE"
  fi

  if [ -s "\$ACME_CONF" ]; then
    . "\$ACME_CONF" || true
    if [ -n "\${Le_NextRenewTime:-}" ]; then
      echo "✅ 下次自动续期：\$(date -u -d "@\$Le_NextRenewTime" '+%Y-%m-%d %H:%M:%S GMT')"
    fi
  fi

  echo "✅ cron：每日 UTC 20:00 执行 acme.sh --cron"
}

acme_cert_valid() {
  [ -s "\$ACME_FULLCHAIN" ] || return 1
  command -v openssl >/dev/null 2>&1 || { apt-get update -y >/dev/null; apt-get install -y openssl >/dev/null; }
  openssl x509 -in "\$ACME_FULLCHAIN" -noout -checkend 0 >/dev/null 2>&1
}

echo "✨ 0. 释放端口"
fuser -k 80/tcp 2>/dev/null || true

echo "✨ 1. 安装基础依赖"
bootstrap_cf_deps() {
  local miss=0
  command -v curl >/dev/null 2>&1 || miss=1
  command -v jq   >/dev/null 2>&1 || miss=1
  command -v openssl >/dev/null 2>&1 || miss=1
  if [ "\$miss" -eq 1 ]; then
    apt-get update -y
    apt-get install -y curl jq ca-certificates openssl
  fi
}
bootstrap_cf_deps

show_cert_info
echo

echo "✨ 2. 获取本机公网 IP"
IP="\$(curl -s https://api.ip.sb/ip || curl -s https://checkip.amazonaws.com)"
[ -z "\$IP" ] && { echo "❌ 获取公网 IP 失败"; exit 1; }
echo "✅ 公网 IP：\$IP"

echo "✨ 3. Cloudflare：生成域名并写 DNS"
CF_API="https://api.cloudflare.com/client/v4"

get_zone_id() {
  curl -s -X GET "\${CF_API}/zones?name=\${DOMAIN}&status=active&per_page=50" \
    -H "Authorization: Bearer \${CF_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result[0].id // empty'
}

ZONE_ID="\$(get_zone_id)"
[ -z "\$ZONE_ID" ] && { echo "❌ ZONE_ID 获取失败"; exit 1; }

update_dns() {
  local name="\$1" proxied="\$2"
  local rid
  rid="\$(curl -s -X GET "\${CF_API}/zones/\$ZONE_ID/dns_records?name=\$name" \
    -H "Authorization: Bearer \$CF_TOKEN" | jq -r '.result[0].id')"

  local data
  data="\$(jq -n --arg type A --arg name "\$name" --arg content "\$IP" --argjson proxied "\$proxied" \
    '{type:\$type,name:\$name,content:\$content,ttl:1,proxied:\$proxied}')"

  if [ "\$rid" != "null" ] && [ -n "\$rid" ]; then
    curl -s -X PUT "\${CF_API}/zones/\$ZONE_ID/dns_records/\$rid" \
      -H "Authorization: Bearer \$CF_TOKEN" -H "Content-Type: application/json" \
      --data "\$data" >/dev/null
  else
    curl -s -X POST "\${CF_API}/zones/\$ZONE_ID/dns_records" \
      -H "Authorization: Bearer \$CF_TOKEN" -H "Content-Type: application/json" \
      --data "\$data" >/dev/null
  fi
}

update_dns "\$SUB_DOMAIN" false
update_dns "\$VX_DOMAIN" true

echo "✅ DNS 已更新：\$SUB_DOMAIN      （灰云，仅DNS）"
echo "✅ DNS 已更新：\$VX_DOMAIN（橙云，CDN加速）"

echo "✨ 4. 保证目标目录永远有可用证书：优先用 acme 已有且未过期的，否则申请新证书"
mkdir -p "\$CERT_BASE"
chmod 700 "\$CERT_BASE"

[ ! -f "\$ACME_SH" ] && curl https://get.acme.sh | sh -s email="\$EMAIL"
export CF_Token="\$CF_TOKEN"

if acme_cert_valid; then
  echo "✅ 检测到 acme.sh 本地证书存在且未过期：复制到目标目录"
else
  echo "ℹ️ acme.sh 本地证书不存在或已过期：申请新证书"
  "\$ACME_SH" --issue --dns dns_cf \
    -d "\$SUB_DOMAIN" -d "\$VX_DOMAIN" \
    --keylength ec-256 --server letsencrypt
fi

[ -s "\$ACME_KEY" ] && cp -f "\$ACME_KEY" "\$KEY_FILE" && chmod 600 "\$KEY_FILE"
[ -s "\$ACME_FULLCHAIN" ] && cp -f "\$ACME_FULLCHAIN" "\$CRT_FILE" && chmod 644 "\$CRT_FILE"

echo "✅ 目标证书文件："
ls -lh "\$KEY_FILE" "\$CRT_FILE"

echo "✨ 5. 写入定时任务（acme.sh 自动续期）"
( crontab -l 2>/dev/null | grep -v acme.sh || true
  echo "0 20 * * * TZ=UTC \"\$ACME_SH\" --cron --home \"\$ACME_HOME\" > /dev/null"
) | crontab -

echo "✅ 证书自动续期已启用（每日 UTC 20:00）"

echo
show_cert_info

# cron：业务脚本已定制 MY_SUB，不再传参
CRON_CMD="/bin/bash /root/cf_dns_and_acme_cert.sh >> /var/log/cf_dns_and_acme_cert.log 2>&1"
( crontab -l 2>/dev/null | grep -v '/root/cf_dns_and_acme_cert.sh' || true
  echo "0 19 * * * TZ=GMT \$CRON_CMD"
) | crontab -

echo "✅ 已加入定时任务：每日 GMT 19:00 执行本脚本（MY_SUB=\${MY_SUB}）"
CFACME_EOF

chmod +x /root/cf_dns_and_acme_cert.sh

# 生成后立刻执行（业务脚本已写死 MY_SUB，无需传参）
bash /root/cf_dns_and_acme_cert.sh
STEP1_EOF

chmod +x /root/step1.sh
echo "✅ 生成器已写入：/root/step1.sh"
echo "用法：bash /root/step1.sh ziyuming"