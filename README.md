# Dargo

**Dargo v1.2** —— Ubuntu VPS 一键部署 Xray + 双 Cloudflare Tunnel + Hysteria2。

适用于已经在 Cloudflare Zero Trust 中创建 Tunnel，并准备好两个 Public Hostname / Tunnel Token 的 VPS。

> 本项目的核心设计是：  
> **一台 VPS，同时运行 VMess-WS + VLESS-WS，每个协议使用独立 Cloudflare Tunnel；另外可选 Hysteria2。**

---

## 功能

- Ubuntu 22.04 / 24.04
- x86_64
- 自动随机生成 UUID
- VMess + WebSocket + TLS + Cloudflare Tunnel
- VLESS + WebSocket + TLS + Cloudflare Tunnel
- 两个独立 Cloudflare Tunnel
- Hysteria2 可选
- Xray 出站支持：
  - VPS 本机出口
  - SOCKS5 代理
  - HTTP 代理
- 安装结束直接输出可复制节点
- 所有节点和参数保存到 `/root/info.txt`
- 自动创建 systemd 服务
- 自动检查 Xray 配置
- 自动处理 APT/DPKG 锁等待
- VMess/VLESS 公网节点端口固定为 **443**

---

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/robertwilliamsc998-ui/Dargo/main/install.sh)
```

或者：

```bash
wget -qO- https://raw.githubusercontent.com/robertwilliamsc998-ui/Dargo/main/install.sh | bash
```

---

# 一、安装前准备

## 1. VPS

建议使用：

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- x86_64

需要 root 权限。

检查：

```bash
cat /etc/os-release
uname -m
```

---

# 二、Cloudflare 准备

Dargo 的 VMess 和 VLESS 使用两个独立 Cloudflare Tunnel。

需要提前在 Cloudflare Zero Trust 中创建：

### Tunnel 1：VMess

例如：

```text
acckhka.example.com
```

Public Hostname：

```text
acckhka.example.com
```

Service：

```text
http://127.0.0.1:22521
```

然后获取 Tunnel Token。

---

### Tunnel 2：VLESS

例如：

```text
acckhkb.example.com
```

Public Hostname：

```text
acckhkb.example.com
```

Service：

```text
http://127.0.0.1:39660
```

然后获取第二个 Tunnel Token。

---

## 非常重要

两个 Tunnel 必须分别绑定：

```text
VMess 域名 → VMess Tunnel → 127.0.0.1:22521
VLESS 域名 → VLESS Tunnel → 127.0.0.1:39660
```

不要把两个 Tunnel 指向同一个 Xray 端口。

---

# 三、安装交互

执行安装命令后，会依次要求输入。

## 1. VMess 域名

例如：

```text
acckhka.example.com
```

---

## 2. VMess 本地端口

默认：

```text
22521
```

这个端口只用于：

```text
Cloudflare Tunnel → VPS → Xray
```

**不是客户端连接端口。**

---

## 3. VMess Tunnel Token

直接粘贴 Cloudflare Tunnel Token。

### v1.2 特别说明

Token 输入现在会**正常显示**。

也就是说：

```text
VMess Cloudflare Tunnel Token: eyJhIjoi...
```

粘贴后可以直接看到内容。

**不会隐藏输入，也不会要求再次确认。**

---

## 4. VLESS 域名

例如：

```text
acckhkb.example.com
```

---

## 5. VLESS 本地端口

默认：

```text
39660
```

同样只用于：

```text
Cloudflare Tunnel → VPS → Xray
```

---

## 6. VLESS Tunnel Token

直接粘贴第二个 Cloudflare Tunnel Token。

输入内容会正常显示。

---

# 四、HY2

安装过程中：

```text
HY2 端口 [8443]:
```

直接回车：

```text
8443
```

然后：

```text
HY2 域名（回车则不启用 HY2）:
```

如果输入域名：

```text
hy2.example.com
```

就会启用 Hysteria2。

如果直接回车：

```text
```

则不安装/启动 HY2。

---

## HY2 注意事项

Hysteria2 使用 UDP。

例如：

```text
UDP 8443
```

因此 VPS 防火墙 / 安全组必须允许对应 UDP 端口。

如果使用自动 ACME 证书，还需要确保域名解析正确，并满足证书签发要求。

---

# 五、PROXY

安装时：

```text
PROXY:
```

直接回车：

```text
```

表示：

```text
Xray → VPS 本机网络出口
```

---

## SOCKS5

例如：

```text
socks5://1.2.3.4:1080
```

---

## HTTP

例如：

```text
http://1.2.3.4:8080
```

---

## 带用户名密码

例如：

```text
socks5://username:password@1.2.3.4:1080
```

或者：

```text
http://username:password@1.2.3.4:8080
```

---

## PROXY 的作用范围

需要特别注意：

```text
PROXY
  ↓
Xray 出站流量
```

也就是说它控制的是 **Xray 处理的代理流量**。

它不会自动改变：

```text
Cloudflared 自身的网络出口
```

也不会自动改变：

```text
Hysteria2 服务自身的网络出口
```

---

# 六、为什么 VMess/VLESS 节点是 443？

这是 Dargo v1.2 的一个重要修正。

VPS 内部：

```text
VMess:
127.0.0.1:22521

VLESS:
127.0.0.1:39660
```

但是客户端连接的是 Cloudflare：

```text
VMess:
acckhka.example.com:443

VLESS:
acckhkb.example.com:443
```

完整链路：

```text
V2RayN
   │
   │ HTTPS / TLS
   │
   │ :443
   ▼
Cloudflare
   │
   │ Tunnel
   ▼
127.0.0.1:22521
   │
   ▼
Xray VMess
```

VLESS：

```text
V2RayN
   │
   │ HTTPS / TLS
   │
   │ :443
   ▼
Cloudflare
   │
   │ Tunnel
   ▼
127.0.0.1:39660
   │
   ▼
Xray VLESS
```

因此：

> **22521 和 39660 是 VPS 内部 Origin 端口，不是客户端节点端口。**

---

# 七、安装完成后的输出

安装成功后会直接显示：

```text
----- VMess-Argo -----
vmess://xxxxxxxxxxxxxxxx

----- VLESS-Argo -----
vless://xxxxxxxxxxxxxxxx

----- Hysteria2 -----
hysteria2://xxxxxxxxxxxxxxxx
```

可以直接复制到支持对应协议的客户端。

---

# 八、节点信息保存位置

安装完成后：

```text
/root/info.txt
```

查看：

```bash
cat /root/info.txt
```

这里会保存：

- UUID
- VMess 节点
- VLESS 节点
- HY2 节点
- 域名
- 公网端口
- 本地端口
- WS Path
- HY2 密码
- PROXY
- 服务状态

---

# 九、重要文件

## Xray

```text
/usr/local/bin/xray
/usr/local/etc/xray/config.json
```

---

## Cloudflared

```text
/opt/cloudflared/cloudflared
```

---

## Hysteria2

```text
/usr/local/bin/hysteria
/etc/hysteria/config.yaml
```

---

## Dargo

```text
/etc/dargo/
```

包括：

```text
variables.env
vmess-token.env
vless-token.env
```

这些文件包含敏感信息，请不要公开上传到 GitHub。

---

# 十、服务

## Xray

```bash
systemctl status xray
```

重启：

```bash
systemctl restart xray
```

日志：

```bash
journalctl -u xray -n 100 --no-pager
```

---

## VMess Cloudflare Tunnel

```bash
systemctl status vmess-argo
```

日志：

```bash
journalctl -u vmess-argo -n 100 --no-pager
```

实时：

```bash
journalctl -u vmess-argo -f
```

---

## VLESS Cloudflare Tunnel

```bash
systemctl status vless-argo
```

日志：

```bash
journalctl -u vless-argo -n 100 --no-pager
```

实时：

```bash
journalctl -u vless-argo -f
```

---

## Hysteria2

```bash
systemctl status hysteria2
```

日志：

```bash
journalctl -u hysteria2 -n 100 --no-pager
```

---

# 十一、检查端口

查看 Xray：

```bash
ss -lntp | grep -E '22521|39660'
```

正常应该看到类似：

```text
127.0.0.1:22521
127.0.0.1:39660
```

HY2：

```bash
ss -lunp | grep 8443
```

---

# 十二、检查 Cloudflare Tunnel

VMess：

```bash
systemctl is-active vmess-argo
```

VLESS：

```bash
systemctl is-active vless-argo
```

正常：

```text
active
```

同时可以查看：

```bash
journalctl -u vmess-argo -n 50 --no-pager
```

以及：

```bash
journalctl -u vless-argo -n 50 --no-pager
```

看到：

```text
Registered tunnel connection
```

说明 cloudflared 已经成功连接 Cloudflare Edge。

---

# 十三、V2RayN 配置

## VMess-Argo

填写：

```text
地址：VMess 域名
端口：443
UUID：安装生成的 UUID
传输协议：WebSocket
TLS：开启
SNI：VMess 域名
Path：/UUID-vm
Host：VMess 域名
```

---

## VLESS-Argo

填写：

```text
地址：VLESS 域名
端口：443
UUID：安装生成的 UUID
加密：none
传输协议：WebSocket
TLS：开启
SNI：VLESS 域名
Path：/UUID-vw
Host：VLESS 域名
```

---

# 十四、端到端测试

推荐从 VPS 外部网络测试。

例如：

```text
手机 5G
        ↓
V2RayN
        ↓
Cloudflare
        ↓
Cloudflare Tunnel
        ↓
Xray
        ↓
PROXY / VPS 出口
        ↓
Internet
```

不要只测试：

```bash
curl 127.0.0.1:22521
```

因为这只能证明 VPS 本机服务存在，不能证明完整链路。

---

# 十五、UUID

Dargo 每次全新安装都会执行：

```bash
uuidgen
```

所以：

```text
第一次安装 → UUID A
第二次全新安装 → UUID B
```

每次都会不同。

UUID 会保存到：

```text
/etc/dargo/variables.env
```

以及：

```text
/root/info.txt
```

---

# 十六、安全提醒

不要把以下内容提交到 GitHub：

```text
Tunnel Token
UUID
HY2 Password
PROXY 用户名密码
```

GitHub 仓库中只应该保存：

```text
install.sh
README.md
```

安装过程中输入的 Token 只保存在 VPS：

```text
/etc/dargo/vmess-token.env
/etc/dargo/vless-token.env
```

权限为：

```text
600
```

---

# 十七、项目

GitHub：

https://github.com/robertwilliamsc998-ui/Dargo

Raw 安装：

https://raw.githubusercontent.com/robertwilliamsc998-ui/Dargo/main/install.sh

---

## License

仅供学习、研究和合法网络管理用途。
