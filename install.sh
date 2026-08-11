#!/usr/bin/env bash
set -Eeuo pipefail

# Dargo v1.2
# Ubuntu 22.04/24.04 x86_64
# Xray + 2 Cloudflare Tunnels + Hysteria2
#
# 重要：
# 1. VMess/VLESS 对外节点均使用 Cloudflare HTTPS 入口 443。
# 2. VMess/VLESS 的本地 Origin 端口仅用于 cloudflared -> Xray，不写入分享节点。
# 3. Token 输入时正常显示，不做二次确认。
# 4. 安装完成后输出所有节点，并保存到 /root/info.txt。

INSTALL_DIR="/etc/dargo"
BIN_DIR="/usr/local/bin"
XRAY_BIN="${BIN_DIR}/xray"
CF_BIN="/opt/cloudflared/cloudflared"
HY2_BIN="${BIN_DIR}/hysteria"
INFO="/root/info.txt"

die(){ echo "[ERROR] $*" >&2; exit 1; }
log(){ echo -e "\n\033[1;36m==> $*\033[0m"; }

[[ $EUID -eq 0 ]] || die "请使用 root 执行。"
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "目前仅支持 Ubuntu。"
[[ "$(uname -m)" == "x86_64" ]] || die "目前仅支持 x86_64。"

wait_for_apt() {
    local timeout=180 elapsed=0 holders=""
    log "检查 APT/DPKG 锁"

    while true; do
        holders="$(fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null || true)"
        if [[ -z "$holders" ]]; then
            break
        fi

        if (( elapsed >= timeout )); then
            echo "仍有进程占用 APT/DPKG 锁：$holders"
            ps -fp $holders 2>/dev/null || true
            die "APT/DPKG 锁等待超时。请确认系统更新任务结束后重新运行安装。"
        fi

        echo "APT/DPKG 正被占用（$holders），等待 5 秒... [$elapsed/$timeout]"
        sleep 5
        elapsed=$((elapsed+5))
    done

    # 不删除 lock 文件。
    dpkg --configure -a
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( "$1" >= 1 && "$1" <= 65535 ))
}

log "检查基础环境"
wait_for_apt
apt-get update -y
apt-get install -y curl wget jq openssl ca-certificates tar gzip unzip uuid-runtime python3

UUID="$(uuidgen)"
VMESS_PORT="22521"
VLESS_PORT="39660"
HY2_PORT="8443"

echo
echo "=============================================="
echo "              Dargo v1.2 安装"
echo "=============================================="
echo "UUID 将自动随机生成："
echo "${UUID}"
echo
echo "说明：VMess/VLESS 节点对外端口固定为 Cloudflare HTTPS 443。"
echo "下面输入的 VMess/VLESS 端口只是 VPS 本机 Origin 端口。"
echo

read -r -p "VMess-Argo 域名: " VMESS_DOMAIN
read -r -p "VMess-Argo 本地端口 [22521]: " x
VMESS_PORT="${x:-22521}"

# 按要求：Token 输入正常显示，不隐藏，不二次确认。
read -r -p "VMess Cloudflare Tunnel Token: " VMESS_TOKEN
echo

read -r -p "VLESS-Argo 域名: " VLESS_DOMAIN
read -r -p "VLESS-Argo 本地端口 [39660]: " x
VLESS_PORT="${x:-39660}"

# 按要求：Token 输入正常显示，不隐藏，不二次确认。
read -r -p "VLESS Cloudflare Tunnel Token: " VLESS_TOKEN
echo

read -r -p "HY2 端口 [8443]: " x
HY2_PORT="${x:-8443}"
read -r -p "HY2 域名（回车则不启用 HY2）: " HY2_DOMAIN
HY2_PASSWORD="$(openssl rand -hex 24)"

echo
echo "Xray 出站代理设置："
echo "  回车                  = VPS 本机出口"
echo "  socks5://IP:PORT     = 通过 SOCKS5 代理出口"
echo "  http://IP:PORT       = 通过 HTTP 代理出口"
read -r -p "PROXY: " PROXY

[[ -n "$VMESS_DOMAIN" && -n "$VMESS_TOKEN" ]] || die "VMess 域名和 Token 不能为空。"
[[ -n "$VLESS_DOMAIN" && -n "$VLESS_TOKEN" ]] || die "VLESS 域名和 Token 不能为空。"

valid_port "$VMESS_PORT" || die "VMess 端口范围错误。"
valid_port "$VLESS_PORT" || die "VLESS 端口范围错误。"
valid_port "$HY2_PORT" || die "HY2 端口范围错误。"

install -d -m 700 "$INSTALL_DIR"
install -d -m 755 /opt/cloudflared
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "安装 Xray"
XRAY_VERSION="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')"
[[ "$XRAY_VERSION" != "null" && -n "$XRAY_VERSION" ]] || die "无法获取 Xray 最新版本。"

curl -fL \
  "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" \
  -o "$TMP/xray.zip"

mkdir -p "$TMP/xray"
unzip -o "$TMP/xray.zip" xray -d "$TMP/xray" >/dev/null
install -m 755 "$TMP/xray/xray" "$XRAY_BIN"

install -d -m 755 /usr/local/etc/xray

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

python3 - "$PROXY" "$UUID" "$VMESS_PORT" "$VLESS_PORT" > /usr/local/etc/xray/config.json <<'PY'
import json
import sys
import urllib.parse

proxy, uuid, vmport, vlport = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

inbounds = [
    {
        "tag": "vmess-ws",
        "listen": "127.0.0.1",
        "port": vmport,
        "protocol": "vmess",
        "settings": {
            "clients": [
                {
                    "id": uuid,
                    "alterId": 0
                }
            ]
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": {
                "path": f"/{uuid}-vm"
            }
        }
    },
    {
        "tag": "vless-ws",
        "listen": "127.0.0.1",
        "port": vlport,
        "protocol": "vless",
        "settings": {
            "clients": [
                {
                    "id": uuid
                }
            ],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": {
                "path": f"/{uuid}-vw"
            }
        }
    }
]

if proxy:
    u = urllib.parse.urlparse(proxy)

    if u.scheme not in ("socks5", "http"):
        raise SystemExit("PROXY 只支持 socks5:// 或 http://")

    if not u.hostname or not u.port:
        raise SystemExit(
            "PROXY 格式错误，应为 socks5://地址:端口 或 http://地址:端口"
        )

    server = {
        "address": u.hostname,
        "port": u.port
    }

    if u.username:
        server["users"] = [{
            "user": urllib.parse.unquote(u.username),
            "pass": urllib.parse.unquote(u.password or "")
        }]

    proto = "socks" if u.scheme == "socks5" else "http"

    outbounds = [
        {
            "tag": "proxy",
            "protocol": proto,
            "settings": {
                "servers": [server]
            }
        },
        {
            "tag": "direct",
            "protocol": "freedom",
            "proxySettings": {
                "tag": "proxy"
            }
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ]
else:
    outbounds = [
        {
            "tag": "direct",
            "protocol": "freedom"
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ]

print(json.dumps({
    "log": {
        "loglevel": "warning"
    },
    "inbounds": inbounds,
    "outbounds": outbounds
}, ensure_ascii=False, indent=2))
PY

"$XRAY_BIN" run -test -config /usr/local/etc/xray/config.json

cat > "$INSTALL_DIR/variables.env" <<EOF
UUID=$UUID
VMESS_PORT=$VMESS_PORT
VLESS_PORT=$VLESS_PORT
HY2_PORT=$HY2_PORT
VMESS_DOMAIN=$VMESS_DOMAIN
VLESS_DOMAIN=$VLESS_DOMAIN
HY2_DOMAIN=$HY2_DOMAIN
PROXY=$PROXY
EOF
chmod 600 "$INSTALL_DIR/variables.env"

log "安装 cloudflared"

curl -fL \
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
  -o "$TMP/cloudflared"

install -m 755 "$TMP/cloudflared" "$CF_BIN"

# Token 文件使用 systemd EnvironmentFile 格式。
printf 'VMESS_TUNNEL_TOKEN=%q\n' "$VMESS_TOKEN" > "$INSTALL_DIR/vmess-token.env"
printf 'VLESS_TUNNEL_TOKEN=%q\n' "$VLESS_TOKEN" > "$INSTALL_DIR/vless-token.env"
chmod 600 "$INSTALL_DIR"/token.env "$INSTALL_DIR"/variables.env

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

curl -fL \
  "https://github.com/apernet/hysteria/releases/download/${HY2_VERSION}/hysteria-linux-amd64" \
  -o "$TMP/hysteria"

install -m 755 "$TMP/hysteria" "$HY2_BIN"

install -d -m 700 /etc/hysteria

if [[ -n "$HY2_DOMAIN" ]]; then
    cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY2_PORT}

acme:
  domains:
    - ${HY2_DOMAIN}
  email: admin@${HY2_DOMAIN}
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
else
    cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY2_PORT}

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com/
    rewriteHost: true
EOF
fi

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

systemctl restart xray
systemctl restart vmess-argo
systemctl restart vless-argo

HY2_ENABLED=0

if [[ -n "$HY2_DOMAIN" ]]; then
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${HY2_PORT}/udp" >/dev/null || true
    fi

    systemctl enable hysteria2 >/dev/null
    systemctl restart hysteria2
    HY2_ENABLED=1
else
    systemctl disable --now hysteria2 >/dev/null 2>&1 || true
fi

# ============================================================
# 节点生成
# ============================================================
#
# 核心修正：
# VMESS_PORT 是本地 Origin 端口，例如 22521。
# VMess 分享节点必须连接 Cloudflare HTTPS，因此对外端口固定 443。
#
# 这里绝对不能写 "$VMESS_PORT"。
#

VMESS_URI="vmess://$(python3 - "$UUID" "$VMESS_DOMAIN" <<'PY'
import base64
import json
import sys

uuid = sys.argv[1]
host = sys.argv[2]

obj = {
    "v": "2",
    "ps": "Dargo-VMess-Argo",
    "add": host,
    "port": "443",
    "id": uuid,
    "aid": "0",
    "scy": "auto",
    "net": "ws",
    "type": "none",
    "host": host,
    "path": f"/{uuid}-vm",
    "tls": "tls",
    "sni": host
}

payload = json.dumps(
    obj,
    separators=(",", ":"),
    ensure_ascii=False
).encode()

print(base64.urlsafe_b64encode(payload).decode())
PY
)"

# VLESS 同样固定 Cloudflare HTTPS 443。
VLESS_URI="vless://${UUID}@${VLESS_DOMAIN}:443?encryption=none&security=tls&sni=${VLESS_DOMAIN}&type=ws&host=${VLESS_DOMAIN}&path=%2F${UUID}-vw#Dargo-VLESS-Argo"

if [[ "$HY2_ENABLED" -eq 1 ]]; then
    HY2_URI="hysteria2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HY2_PORT}/?sni=${HY2_DOMAIN}&insecure=0#Dargo-Hysteria2"
else
    HY2_URI="未启用：没有填写 HY2 域名"
fi

cat > "$INFO" <<EOF
Dargo v1.2
生成时间: $(date -Is)

================ UUID ================
$UUID

================ VMess-Argo ================
域名: $VMESS_DOMAIN
对外端口: 443
本地 Origin 端口: $VMESS_PORT
WS Path: /${UUID}-vm

$VMESS_URI

================ VLESS-Argo ================
域名: $VLESS_DOMAIN
对外端口: 443
本地 Origin 端口: $VLESS_PORT
WS Path: /${UUID}-vw

$VLESS_URI

================ Hysteria2 ================
域名: ${HY2_DOMAIN:-未设置}
端口: $HY2_PORT
密码: $HY2_PASSWORD

$HY2_URI

================ PROXY ================
${PROXY:-未设置（VPS 本机出口）}

================ 服务状态 ================
xray: $(systemctl is-active xray || true)
vmess-argo: $(systemctl is-active vmess-argo || true)
vless-argo: $(systemctl is-active vless-argo || true)
hysteria2: $(systemctl is-active hysteria2 || true)

================ 说明 ================
VMess/VLESS:
  Cloudflare public hostname -> HTTPS 443 -> Tunnel -> VPS localhost Origin
  VMess Origin: 127.0.0.1:${VMESS_PORT}
  VLESS Origin: 127.0.0.1:${VLESS_PORT}

因此分享节点端口固定为 443，而不是 Origin 端口。

HY2:
  直接使用 VPS UDP ${HY2_PORT}
EOF

chmod 600 "$INFO"

echo
echo "=============================================="
echo "              Dargo v1.2 安装完成"
echo "=============================================="
echo

echo "----- VMess-Argo -----"
echo "对外端口：443"
echo "本地 Origin：127.0.0.1:${VMESS_PORT}"
echo "$VMESS_URI"
echo

echo "----- VLESS-Argo -----"
echo "对外端口：443"
echo "本地 Origin：127.0.0.1:${VLESS_PORT}"
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
echo "注意："
echo "1. VMess/VLESS 两个 Cloudflare Tunnel 必须分别绑定对应 public hostname。"
echo "2. VMess Tunnel Origin 应指向 http://127.0.0.1:${VMESS_PORT}。"
echo "3. VLESS Tunnel Origin 应指向 http://127.0.0.1:${VLESS_PORT}。"
echo "4. VMess/VLESS 客户端节点端口均为 443。"
echo "5. HY2 需要真实域名并能完成 ACME 证书签发。"
echo "6. PROXY 只控制 Xray 的代理出站，不改变 Cloudflared/HY2 自身出口。"
echo "7. 完整节点信息：$INFO"
echo "=============================================="
