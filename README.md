# Dargo

Dargo 是一个面向 Ubuntu VPS 的一键部署脚本，目标是快速部署：

- VMess + WebSocket + Cloudflare Tunnel
- VLESS + WebSocket + Cloudflare Tunnel
- Hysteria2
- 可选 HTTP / SOCKS5 出站代理
- systemd 开机自启
- 安装完成输出节点
- `/root/info.txt` 保存节点信息

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/robertwilliamsc998-ui/Dargo/main/install.sh)
```

## 安装前准备

Cloudflare Zero Trust 中先创建两个独立 Tunnel：

1. VMess Tunnel
2. VLESS Tunnel

分别建立 Public Hostname：

```text
VMess 域名 -> http://127.0.0.1:22521
VLESS 域名 -> http://127.0.0.1:39660
```

安装时分别输入域名、端口、Token。

## PROXY

留空：

```text
VPS 本机出口
```

或者：

```text
socks5://127.0.0.1:1080
http://1.2.3.4:8080
```

Dargo 会把 Xray 的代理出站流量通过该代理发送。

## HY2

HY2 需要真实域名用于 ACME TLS 证书。

安装时填写：

```text
HY2 域名
HY2 UDP 端口
```

然后脚本自动生成密码。

## 服务

```bash
systemctl status xray
systemctl status vmess-argo
systemctl status vless-argo
systemctl status hysteria2
```

## 节点信息

```bash
cat /root/info.txt
```

## Xray 配置检查

```bash
xray run -test -config /usr/local/etc/xray/config.json
```

## 查看 Tunnel 日志

```bash
journalctl -u vmess-argo -f
journalctl -u vless-argo -f
```

## 卸载

Dargo 不提供自动删除 VPS 的功能。建议确认备份 `/root/info.txt` 后手动删除：

```bash
systemctl disable --now vmess-argo vless-argo xray hysteria2 2>/dev/null || true
rm -f /etc/systemd/system/vmess-argo.service
rm -f /etc/systemd/system/vless-argo.service
rm -f /etc/systemd/system/hysteria2.service
rm -f /etc/systemd/system/xray.service
systemctl daemon-reload
```

然后根据实际情况删除：

```text
/etc/dargo
/etc/hysteria
/usr/local/etc/xray
/usr/local/bin/xray
/usr/local/bin/hysteria
/opt/cloudflared
```

## 安全

Cloudflare Tunnel Token 不得提交到 GitHub。

`/etc/dargo/*token.env` 权限为 600。
