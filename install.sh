#!/usr/bin/env bash
set -Eeuo pipefail

# Dargo v1.0
# Ubuntu 22.04/24.04 x86_64
# Installs Xray + two independent Cloudflare Tunnel services + Hysteria2.
# Never stores Cloudflare tokens in the Git repository.

REPO_RAW="${DARGO_RAW_BASE:-https://raw.githubusercontent.com/robertwilliamsc998-ui/Dargo/main}"
INSTALL_DIR="/etc/dargo"
BIN_DIR="/usr/local/bin"
XRAY_BIN="${BIN_DIR}/xray"
CF_BIN="/opt/cloudflared/cloudflared"
HY2_BIN="/usr/local/bin/hysteria"
INFO="/root/info.txt"

die(){ echo "[ERROR] $*" >&2; exit 1; }
log(){ echo -e "\n\033[1;36m==> $*\033[0m"; }

[[ $EUID -eq 0 ]] || die "请使用 root 执行。"
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "目前仅支持 Ubuntu。"
[[ "$(uname -m)" == "x86_64" ]] || die "目前仅支持 x86_64。"

log "检查基础环境"
apt-get update -y
apt-get install -y curl wget jq openssl ca-certificates tar gzip unzip uuid-runtime openssl

UUID="$(uuidgen)"
VMESS_PORT="22521"
VLESS_PORT="39660"
HY2_PORT="8443"

echo
echo "=============================================="
echo "              Dargo v1.0 安装"
echo "=============================================="
echo "UUID 将自动随机生成："
echo "${UUID}"
echo

read -r -p "VMess-Argo 域名: " VMESS_DOMAIN
read -r -p "VMess-Argo 本地端口 [22521]: " x
VMESS_PORT="${x:-22521}"
read -r -s -p "VMess Cloudflare Tunnel Token: " VMESS_TOKEN
echo

read -r -p "VLESS-Argo 域名: " VLESS_DOMAIN
read -r -p "VLESS-Argo 本地端口 [39660]: " x
VLESS_PORT="${x:-39660}"
read -r -s -p "VLESS Cloudflare Tunnel Token: " VLESS_TOKEN
echo

read -r -p "HY2 端口 [8443]: " x
HY2_PORT="${x:-8443}"
read -r -p "HY2 域名（没有域名可直接回车，稍后仍会安装 HY2）: " HY2_DOMAIN
HY2_PASSWORD="$(openssl rand -hex 24)"

echo
echo "出站代理设置："
echo "  回车        = VPS 本机出口"
echo "  socks5://IP:PORT"
echo "  http://IP:PORT"
read -r -p "PROXY: " PROXY

[[ -n "$VMESS_DOMAIN" && -n "$VMESS_TOKEN" ]] || die "VMess 域名和 Token 不能为空。"
[[ -n "$VLESS_DOMAIN" && -n "$VLESS_TOKEN" ]] || die "VLESS 域名和 Token 不能为空。"
[[ "$VMESS_PORT" =~ ^[0-9]+$ && "$VLESS_PORT" =~ ^[0-9]+$ && "$HY2_PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字。"

install -d -m 700 "$INSTALL_DIR"
install -d -m 755 /opt/cloudflared

log "安装 Xray"
XRAY_VERSION="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')"
[[ "$XRAY_VERSION" != "null" && -n "$XRAY_VERSION" ]] || die "无法获取 Xray 最新版本。"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" -o "$TMP/xray.zip"
unzip -o "$TMP/xray.zip" xray -d "$TMP/xray"
install -m 755 "$TMP/xray/xray" "$XRAY_BIN"

install -d -m 755 /usr/local/etc/xray
install -d -m 755 /etc/systemd/system/xray.service.d

cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Dargo Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

log "生成 Xray 配置"
python3 - "$INSTALL_DIR/variables.env" <<PY
from pathlib import Path
Path("$INSTALL_DIR/variables.env").write_text(
"""UUID=$UUID
VMESS_PORT=$VMESS_PORT
VLESS_PORT=$VLESS_PORT
HY2_PORT=$HY2_PORT
VMESS_DOMAIN=$VMESS_DOMAIN
VLESS_DOMAIN=$VLESS_DOMAIN
HY2_DOMAIN=$HY2_DOMAIN
PROXY=$PROXY
""")
PY
chmod 600 "$INSTALL_DIR/variables.env"

python3 - "$PROXY" "$UUID" "$VMESS_PORT" "$VLESS_PORT" > /usr/local/etc/xray/config.json <<'PY'
import json, sys, urllib.parse
proxy=sys.argv[1]
uuid=sys.argv[2]
vmport=int(sys.argv[3]); vlport=int(sys.argv[4])

inbounds=[
 {
  "tag":"vmess-ws","listen":"127.0.0.1","port":vmport,"protocol":"vmess",
  "settings":{"clients":[{"id":uuid,"alterId":0}]},
  "streamSettings":{"network":"ws","wsSettings":{"path":f"/{uuid}-vm"}}
 },
 {
  "tag":"vless-ws","listen":"127.0.0.1","port":vlport,"protocol":"vless",
  "settings":{"clients":[{"id":uuid}],"decryption":"none"},
  "streamSettings":{"network":"ws","wsSettings":{"path":f"/{uuid}-vw"}}
 }
]

outbounds=[]
if proxy:
    u=urllib.parse.urlparse(proxy)
    if u.scheme not in ("socks5","http"):
        raise SystemExit("PROXY 只支持 socks5:// 或 http://")
    if not u.hostname or not u.port:
        raise SystemExit("PROXY 格式错误，应为 socks5://地址:端口 或 http://地址:端口")
    settings={"servers":[{"address":u.hostname,"port":u.port}]}
    if u.username:
        settings["servers"][0]["users"]=[{"user":urllib.parse.unquote(u.username),
                                           "pass":urllib.parse.unquote(u.password or "")}]
    proto="socks" if u.scheme=="socks5" else "http"
    outbounds.append({"tag":"proxy","protocol":proto,"settings":settings})
    outbounds.append({"tag":"direct","protocol":"freedom","proxySettings":{"tag":"proxy"}})
else:
    outbounds.append({"tag":"direct","protocol":"freedom"})

outbounds.append({"tag":"block","protocol":"blackhole"})
print(json.dumps({"log":{"loglevel":"warning"},"inbounds":inbounds,
                  "outbounds":outbounds},ensure_ascii=False,indent=2))
PY

"$XRAY_BIN" run -test -config /usr/local/etc/xray/config.json

log "安装 cloudflared"
CF_VERSION="$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest | jq -r '.tag_name')"
[[ "$CF_VERSION" != "null" && -n "$CF_VERSION" ]] || die "无法获取 cloudflared 最新版本。"
curl -fL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o "$TMP/cloudflared"
install -m 755 "$TMP/cloudflared" "$CF_BIN"

cat > /etc/dargo/vmess-token.env <<EOF
VMESS_TUNNEL_TOKEN=$(printf '%q' "$VMESS_TOKEN")
EOF
cat > /etc/dargo/vless-token.env <<EOF
VLESS_TUNNEL_TOKEN=$(printf '%q' "$VLESS_TOKEN")
EOF
chmod 600 /etc/dargo/*token.env

cat > /etc/systemd/system/vmess-argo.service <<'EOF'
[Unit]
Description=Dargo Cloudflare Tunnel - VMess WS
After=network-online.target xray.service
Wants=network-online.target
Requires=xray.service

[Service]
Type=simple
User=root
NoNewPrivileges=yes
TimeoutStartSec=0
EnvironmentFile=/etc/dargo/vmess-token.env
ExecStart=/opt/cloudflared/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token ${VMESS_TUNNEL_TOKEN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/vless-argo.service <<'EOF'
[Unit]
Description=Dargo Cloudflare Tunnel - VLESS WS
After=network-online.target xray.service
Wants=network-online.target
Requires=xray.service

[Service]
Type=simple
User=root
NoNewPrivileges=yes
TimeoutStartSec=0
EnvironmentFile=/etc/dargo/vless-token.env
ExecStart=/opt/cloudflared/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token ${VLESS_TUNNEL_TOKEN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log "安装 Hysteria2"
HY2_VERSION="$(curl -fsSL https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name')"
[[ "$HY2_VERSION" != "null" && -n "$HY2_VERSION" ]] || die "无法获取 Hysteria2 最新版本。"
HY2_URL="https://github.com/apernet/hysteria/releases/download/${HY2_VERSION}/hysteria-linux-amd64"
curl -fL "$HY2_URL" -o "$TMP/hysteria"
install -m 755 "$TMP/hysteria" "$HY2_BIN"

install -d -m 700 /etc/hysteria
cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY2_PORT}
acme:
  domains:
    - ${HY2_DOMAIN:-localhost}
  email: admin@${HY2_DOMAIN:-localhost}
  type: http

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com/
    rewriteHost: true
EOF

# If no real domain was supplied, do not start HY2 because ACME cannot work.
cat > /etc/systemd/system/hysteria2.service <<'EOF'
[Unit]
Description=Dargo Hysteria2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

log "启用服务"
systemctl daemon-reload
systemctl enable xray vmess-argo vless-argo >/dev/null
systemctl restart xray vmess-argo vless-argo

HY2_ENABLED=0
if [[ -n "$HY2_DOMAIN" ]]; then
    # Open firewall if UFW exists and is active.
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${HY2_PORT}/udp" >/dev/null || true
    fi
    systemctl enable hysteria2 >/dev/null
    systemctl restart hysteria2
    HY2_ENABLED=1
else
    systemctl disable --now hysteria2 >/dev/null 2>&1 || true
fi

VMESS_URI="vmess://$(python3 - "$UUID" "$VMESS_DOMAIN" "$VMESS_PORT" <<'PY'
import base64,json,sys
u,host,port=sys.argv[1],sys.argv[2],sys.argv[3]
obj={"v":"2","ps":"Dargo-VMess-Argo","add":host,"port":port,"id":u,"aid":"0",
     "scy":"auto","net":"ws","type":"none","host":host,
     "path":f"/{u}-vm","tls":"tls","sni":host}
print(base64.urlsafe_b64encode(json.dumps(obj,separators=(",",":")).encode()).decode())
PY
)"

VLESS_URI="vless://${UUID}@${VLESS_DOMAIN}:443?encryption=none&security=tls&sni=${VLESS_DOMAIN}&type=ws&host=${VLESS_DOMAIN}&path=%2F${UUID}-vw#Dargo-VLESS-Argo"

if [[ "$HY2_ENABLED" -eq 1 ]]; then
    HY2_URI="hysteria2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HY2_PORT}/?sni=${HY2_DOMAIN}&insecure=0#Dargo-Hysteria2"
else
    HY2_URI="未启用：安装时没有填写 HY2 域名（ACME 证书需要真实域名）"
fi

cat > "$INFO" <<EOF
Dargo v1.0
生成时间: $(date -Is)

UUID:
$UUID

VMess-Argo:
域名: $VMESS_DOMAIN
本地端口: $VMESS_PORT
WS Path: /${UUID}-vm

$VMESS_URI

VLESS-Argo:
域名: $VLESS_DOMAIN
本地端口: $VLESS_PORT
WS Path: /${UUID}-vw

$VLESS_URI

Hysteria2:
域名: ${HY2_DOMAIN:-未设置}
端口: $HY2_PORT
密码: $HY2_PASSWORD

$HY2_URI

PROXY:
${PROXY:-未设置（VPS 本机出口）}

服务:
$(systemctl is-active xray || true)
$(systemctl is-active vmess-argo || true)
$(systemctl is-active vless-argo || true)
$(systemctl is-active hysteria2 || true)
EOF
chmod 600 "$INFO"

echo
echo "=============================================="
echo "              Dargo 安装完成"
echo "=============================================="
echo
echo "UUID:"
echo "$UUID"
echo
echo "----- VMess-Argo -----"
echo "$VMESS_URI"
echo
echo "----- VLESS-Argo -----"
echo "$VLESS_URI"
echo
echo "----- Hysteria2 -----"
echo "$HY2_URI"
echo
echo "PROXY: ${PROXY:-未设置（VPS 本机出口）}"
echo
echo "完整信息已保存：$INFO"
echo
echo "服务状态："
systemctl --no-pager --full status xray | sed -n '1,8p'
systemctl --no-pager --full status vmess-argo | sed -n '1,8p'
systemctl --no-pager --full status vless-argo | sed -n '1,8p'
if [[ "$HY2_ENABLED" -eq 1 ]]; then
  systemctl --no-pager --full status hysteria2 | sed -n '1,8p'
fi
echo
echo "=============================================="
echo "提示："
echo "1. Cloudflare Tunnel 的 public hostname 必须已经指向对应 Tunnel。"
echo "2. VMess/VLESS 的 Cloudflare origin service 应分别指向本机对应端口。"
echo "3. HY2 必须有真实域名并能完成 ACME 证书签发。"
echo "=============================================="
