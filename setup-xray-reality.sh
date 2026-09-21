#!/bin/sh
# Xray VLESS+REALITY 通用部署 (Alpine/Debian/RHEL, IPv4/IPv6 自适应)
# 变量: PORT(46683) SNI_DOMAIN(www.bing.com) XRAY_VER(v26.6.27) REUSE=1 NO_DEST_GUARD=1
set -e
SNI_DOMAIN="${SNI_DOMAIN:-www.bing.com}"
XRAY_VER="${XRAY_VER:-v26.6.27}"; REUSE="${REUSE:-0}"; ENV_FILE=/etc/xray/node.env
# ---- 端口选择 ----
# 1) 已设 PORT 环境变量 -> 直接用（兼容 CI / 管道部署 / PORT=xxx bash 脚本）
# 2) 交互式 TTY        -> 提示输入，默认 46683
# 3) 非交互(管道)      -> 用默认 46683
PORT="${PORT:-}"
if [ -z "$PORT" ] && [ -t 0 ]; then
  printf '请输入监听端口 [默认 46683，建议避开 22/80/443 等常用端口]: '
  read -r PORT
fi
PORT="${PORT:-46683}"
case "$PORT" in
  *[!0-9]*) echo "端口非法: $PORT"; exit 1;;
  *) [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "端口超出范围(1-65535): $PORT"; exit 1; };;
esac
echo "  使用端口: $PORT"
DEST_GOOD="www.bing.com dl.google.com itunes.apple.com gateway.icloud.com"
DEST_BAD="www.microsoft.com swdist.apple.com addons.mozilla.org www.lovelive-anime.jp"
echo "== Xray VLESS+REALITY 部署 =="

# [0] 系统识别
if [ -f /etc/os-release ]; then . /etc/os-release; OS="${PRETTY_NAME:-$ID}"; fi
if command -v apk >/dev/null 2>&1; then PKG=apk
elif command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf >/dev/null 2>&1; then PKG=dnf
elif command -v yum >/dev/null 2>&1; then PKG=yum
else echo "不支持的包管理器"; exit 1; fi
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then INIT=systemd
elif command -v rc-update >/dev/null 2>&1; then INIT=openrc
elif command -v systemctl >/dev/null 2>&1; then INIT=systemd
else echo "不支持的 init"; exit 1; fi
echo "[0] $OS / $PKG / $INIT"

svc(){ # svc <stop|restart|enable|disable> <name>
  if [ "$INIT" = systemd ]; then systemctl "$1" "$2" >/dev/null 2>&1 || true
  elif [ "$1" = disable ]; then rc-update del "$2" default >/dev/null 2>&1 || true
  else rc-service "$2" "$1" >/dev/null 2>&1 || service "$2" "$1" >/dev/null 2>&1 || true; fi
}

# [1] REUSE 复用旧凭证
if [ "$REUSE" = 1 ] && [ -f "$ENV_FILE" ]; then
  . "$ENV_FILE"
  if [ -n "$NODE_UUID" ] && [ -n "$NODE_PRIVATE_KEY" ]; then
    UUID="$NODE_UUID"; PRIV="$NODE_PRIVATE_KEY"; PUB="$NODE_PUBLIC_KEY"; SID="$NODE_SHORT_ID"
    echo "[1] REUSE: $UUID"
  fi
fi

# [2] 清理旧服务 / Xboard 遗留 agent
echo "[2] 清理..."
for s in xray sing-box xboard-node; do svc stop "$s"; svc disable "$s"; done
pkill -9 -f xboard-node >/dev/null 2>&1 || true
rm -rf /etc/xray /etc/sing-box /etc/xboard-node /etc/init.d/xray /etc/init.d/sing-box /etc/init.d/xboard-node
rm -f /etc/systemd/system/xray.service /etc/systemd/system/sing-box.service /etc/systemd/system/xboard-node.service

# [3] 依赖
echo "[3] 依赖..."
case "$PKG" in
  apk) apk add -q curl unzip openssl ca-certificates iproute2 iptables >/dev/null 2>&1 || true;;
  apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl unzip openssl ca-certificates iproute2 iptables >/dev/null 2>&1 || true;;
  dnf|yum) $PKG install -y curl unzip openssl ca-certificates iproute iptables >/dev/null 2>&1 || true;;
esac

# [4] 下载 Xray-core
echo "[4] Xray $XRAY_VER"
mkdir -p /usr/local/bin /etc/xray
case "$(uname -m)" in x86_64|amd64) A=64;; aarch64|arm64) A=arm64-v8a;; armv7l) A=arm32-v7a;; s390x) A=s390x;; *) echo "不支持架构"; exit 1;; esac
if [ ! -x /usr/local/bin/xray ]; then
  rm -f /tmp/x.zip
  for b in github.com ghproxy.net/https://github.com ghp.ci/https://github.com gh-proxy.com/https://github.com; do
    echo "  下载 $b"; curl -sL -f --max-time 120 -o /tmp/x.zip "https://$b/XTLS/Xray-core/releases/download/$XRAY_VER/Xray-linux-$A.zip" && [ -s /tmp/x.zip ] && break
  done
  [ -s /tmp/x.zip ] || { echo "下载失败"; exit 1; }
  unzip -o /tmp/x.zip -d /tmp/xe >/dev/null; mv /tmp/xe/xray /usr/local/bin/xray; chmod +x /usr/local/bin/xray; rm -rf /tmp/x.zip /tmp/xe
fi
/usr/local/bin/xray version >/dev/null 2>&1 || { echo "xray 无法执行"; exit 1; }
echo "  $(/usr/local/bin/xray version 2>/dev/null | head -1)"

# [5] 凭证 + dest 守卫 + 协议栈
echo "[5] 配置..."
# 端口占用检查：避免抢了用户其它服务（xray 自身旧进程会被下面清理，不计冲突）
if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
  if command -v ss >/dev/null 2>&1; then
    OCC=$(ss -tlnp 2>/dev/null | grep ":$PORT " | grep -oE '"[^"]+"' | tr -d '"' | sort -u | grep -v '^$' | tr '\n' ',')
  else
    OCC=$(netstat -tlnp 2>/dev/null | grep ":$PORT " | awk '{print $NF}' | cut -d/ -f2 | sort -u | grep -v '^$' | tr '\n' ',')
  fi
  if [ -n "$OCC" ] && ! echo "$OCC" | grep -q xray && ! echo "$OCC" | grep -q xboard-node; then
    echo "  [警告] 端口 $PORT 已被其它服务占用: ${OCC%,}"
    if [ -t 0 ]; then
      printf '  是否仍要继续使用该端口(会尝试接管)? [y/N]: '
      read -r CONT
      case "$CONT" in y|Y|yes|YES) echo "  已确认继续";; *) echo "已取消，请换端口后重跑 (PORT=xxx bash $0)"; exit 1;; esac
    else
      echo "  [错误] 非交互模式检测到端口冲突，已中止。请用 PORT 变量指定其他端口。"
      exit 1
    fi
  fi
fi
if [ -z "$UUID" ]; then
  UUID=$(/usr/local/bin/xray uuid)
  openssl genpkey -algorithm x25519 -out /tmp/k.pem
  PRIV=$(openssl pkey -in /tmp/k.pem -outform DER | tail -c32 | base64 | tr '+/' '-_' | tr -d '=\r\n')
  openssl pkey -in /tmp/k.pem -pubout -out /tmp/k.pub
  PUB=$(openssl pkey -pubin -in /tmp/k.pub -outform DER | tail -c32 | base64 | tr '+/' '-_' | tr -d '=\r\n')
  SID=$(openssl rand -hex 8); rm -f /tmp/k.pem /tmp/k.pub
fi
if [ "${NO_DEST_GUARD:-0}" != 1 ]; then
  for b in $DEST_BAD; do
    if [ "$SNI_DOMAIN" = "$b" ]; then echo "  ! $SNI_DOMAIN 不兼容->bing"; SNI_DOMAIN=www.bing.com; fi
  done
  reach(){ command -v nc >/dev/null 2>&1 && nc -z -w5 "$1" 443 2>/dev/null && return 0; curl -s -o /dev/null --max-time 6 "https://$1" 2>/dev/null; }
  if ! reach "$SNI_DOMAIN"; then
    for c in $DEST_GOOD; do if reach "$c"; then SNI_DOMAIN=$c; break; fi; done
  fi
  echo "  dest=$SNI_DOMAIN"
fi
# 协议栈: 有 IPv6 即 listen=:: (Linux 双栈 socket 同时接 v4+v6), 仅 IPv4 才 0.0.0.0
has_v6=0; has_v4=0
if grep -vE '^00000000000000000000000000000001' /proc/net/if_inet6 2>/dev/null | grep -q .; then has_v6=1; fi
if ip -4 addr show 2>/dev/null | grep -qE 'inet '; then has_v4=1; fi
if [ "$has_v6" = 1 ] && [ "$has_v4" = 1 ]; then LISTEN='"::"'; STRAT=AsIs; STACK=dual
elif [ "$has_v6" = 1 ]; then LISTEN='"::"'; STRAT=AsIs; STACK=ipv6only
else LISTEN='"0.0.0.0"'; STRAT=UseIPv4; STACK=ipv4only; fi
echo "  协议栈=$STACK listen=$LISTEN"

cat > /etc/xray/config.json <<JSON
{
  "log": {"loglevel":"warning"},
  "inbounds":[{
    "listen": ${LISTEN},
    "port": ${PORT},
    "protocol":"vless",
    "settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},
    "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
      "show":false,"dest":"${SNI_DOMAIN}:443","xver":0,
      "serverNames":["${SNI_DOMAIN}"],"privateKey":"${PRIV}","shortIds":["${SID}"]}}
  }],
  "outbounds":[{"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"${STRAT}"}}]
}
JSON
/usr/local/bin/xray run -test -c /etc/xray/config.json >/dev/null 2>&1 || { echo "配置校验失败:"; /usr/local/bin/xray run -test -c /etc/xray/config.json 2>&1 | tail -5; exit 1; }

cat > "$ENV_FILE" <<ENVF
NODE_UUID="$UUID"
NODE_PRIVATE_KEY="$PRIV"
NODE_PUBLIC_KEY="$PUB"
NODE_SHORT_ID="$SID"
NODE_PORT="$PORT"
NODE_SNI="$SNI_DOMAIN"
ENVF
chmod 600 "$ENV_FILE"

iptables -C INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || true
if [ "$STACK" != ipv4only ]; then ip6tables -C INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || true; fi

# [6] 服务安装
echo "[6] 服务..."
if [ "$INIT" = systemd ]; then
  cat > /etc/systemd/system/xray.service <<'U'
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
U
  systemctl daemon-reload; systemctl enable xray >/dev/null 2>&1 || true; systemctl restart xray
else
  cat > /etc/init.d/xray <<'S'
#!/sbin/openrc-run
command=/usr/local/bin/xray
command_args="run -c /etc/xray/config.json"
command_background=yes
pidfile=/run/xray.pid
output_log=/var/log/xray.log
error_log=/var/log/xray.log
depend(){ need net; after firewall; }
S
  chmod +x /etc/init.d/xray; rc-update add xray default >/dev/null 2>&1 || true; rc-service xray restart >/dev/null 2>&1 || service xray restart >/dev/null 2>&1 || true
fi
sleep 2

# [7] 端口自检
echo "[7] 端口..."
L=$(ss -tlnp 2>/dev/null | grep ":$PORT " | grep -oE '"[^"]+"' | tr -d '"' | sort -u) || true
if pgrep -x xray >/dev/null 2>&1 && [ -z "$L" ]; then L=xray; fi
echo "  占用 $PORT: ${L:-none}"
if ! echo "$L" | grep -q xray; then
  echo "  [错误] xray 未监听 $PORT"
  if [ "$INIT" = systemd ]; then systemctl status xray --no-pager || true; journalctl -u xray -n30 --no-pager || true; fi
  exit 1
fi

# 链接 (IPv6 自动包方括号)
IP=$(curl -s4 --max-time 6 ifconfig.me 2>/dev/null || curl -s4 --max-time 6 api.ipify.org 2>/dev/null) || true
if [ -z "$IP" ]; then IP=$(curl -s6 --max-time 6 ifconfig.me 2>/dev/null || curl -s6 --max-time 6 api.ipify.org 2>/dev/null) || true; fi
[ -z "$IP" ] && IP=你的服务器IP
case "$IP" in *:*) H="[$IP]";; *) H="$IP";; esac
LINK="vless://${UUID}@${H}:${PORT}?type=tcp&security=reality&encryption=none&pbk=${PUB}&fp=chrome&sni=${SNI_DOMAIN}&sid=${SID}&flow=xtls-rprx-vision#XRAY-${SNI_DOMAIN}-${PORT}"
echo "=================================================================="
echo "完成: $OS / $INIT  协议栈=$STACK"
echo "UUID=$UUID"
echo "pbk =$PUB"
echo "sid =$SID"
echo "sni =$SNI_DOMAIN"
echo "链接: $LINK"
echo "=================================================================="
