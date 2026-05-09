# VPS 开荒脚本 V3.0.0

> **银趴火山帮** 出品 · SSH · BBR · DDNS · Caddy · Firewall

一键式 VPS 初始化与管理工具，覆盖安全加固、网络调优、服务部署全流程。支持 Debian / Ubuntu / CentOS / Alpine / OpenWrt 等主流系统。

---

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh)
```

**安装到本地后用快捷键 `v` 呼出：**

进入脚本 → `m) 脚本管理` → `1) 安装脚本 + 设置快捷键`

之后任意终端输入 `v` 即可启动。

---

## 主界面

```
    ______  _______  ___    ____  ______   ____  ____  _____
   /  _/  |/  / __ \/   |  / __ \/_  __/  / __ \/ __ \/ ___/
   ...

════════════════════════════════════════
       VPS 开荒脚本 V3.0.0
  ··银趴火山帮··
────────────────────────────────────────
  端口 22  |  公钥数 1
  密码登录 no  |  公钥认证 yes
  BBR: bbr  |  限速: 无限速
  Fail2ban: running
  防火墙: ufw active
  Caddy: running
  DDNS: 运行中
  时间: 2026-05-09 16:30:00  Asia/Shanghai
────────────────────────────────────────
  [安全与网络]
  1) SSH 工具集
  2) Fail2ban 管理
  3) BBR TCP 调优
  4) 防火墙管理
  5) DNS 优化
  6) Cloudflare DDNS

  [系统与服务]
  7) 系统换源
  8) IPv4/IPv6 配置
  9) Caddy 管理
  p) 端口转发
  t) 时间同步
  s) Swap 管理
  m) 脚本管理（安装 / 更新 / 卸载）
  0) 退出
════════════════════════════════════════
```

状态栏实时显示 SSH 端口、BBR、Fail2ban、防火墙、Caddy、DDNS 运行状态，以及当前时间时区。有新版本时顶部显示 🔔 提示。

---

## 功能详解

### 1. SSH 工具集

| 功能 | 说明 |
|------|------|
| 查看已有公钥 | 列出所有已授权公钥，显示指纹和备注 |
| 添加公钥 | 粘贴公钥内容添加到 `~/.ssh/authorized_keys` |
| 删除公钥 | 按编号删除指定公钥 |
| 生成密钥对 | 生成 Ed25519 或 RSA-4096 密钥对，支持直接添加到服务器 |
| 设置登录方式 | 仅密钥 / 密码+密钥 / 仅密码（三种模式切换） |
| 修改 SSH 端口 | 自动备份配置、语法验证、防火墙同步放行/关闭旧端口 |

**修改端口时会自动：**
- 检测并放行新端口（ufw / firewalld / iptables）
- 关闭旧端口
- 提示保持当前连接不断开，新开终端验证

---

### 2. Fail2ban 管理

自动封禁 SSH 暴力破解 IP。

**安装时自动处理：**
- 检测 `python3-systemd` 模块，自动选择 `systemd` 或 `auto` backend
- backend 不可用时自动安装 `rsyslog` 补充日志源
- 等待 socket 建立（最多 8 秒），失败时备用方式启动
- 支持 `/run/fail2ban/` 和 `/var/run/fail2ban/` 双路径探测

| 功能 | 说明 |
|------|------|
| 查看封禁 IP 列表 | 列出当前所有被封禁的 IP |
| 手动解封 IP | 输入 IP 地址立即解封 |
| 实时日志 | 彩色显示封禁/解封/尝试记录，支持实时跟踪 |
| 基础参数配置 | 修改封禁时长、时间窗口、最大重试次数、监控端口，含快速预设 |
| 编辑配置文件 | 直接用 nano 编辑 `jail.local` |
| 安装/更新 | 一键更新到最新版 |
| 卸载 | 完整移除 |

**快速预设：**

| 预设 | bantime | findtime | maxretry |
|------|---------|----------|----------|
| 严格模式 | 1天 | 10分钟 | 3次 |
| 标准模式 | 1小时 | 10分钟 | 5次 |
| 宽松模式 | 30分钟 | 5分钟 | 10次 |
| 永久封禁 | 永久 | 10分钟 | 3次 |

---

### 3. BBR TCP 调优

**智能向导（推荐）**

根据当前内存自动推荐预设，也可手动选择三种场景：

| 预设 | 适用场景 | 缓冲区 |
|------|---------|--------|
| `balanced` 均衡跨境 | 网页/代理/日常综合（默认推荐） | 64MB |
| `latency` 低延迟交互 | SSH/游戏/远程桌面/小包优先 | 32MB |
| `throughput` 高吞吐传输 | 大带宽/高延迟/下载上传 | 128MB |

**自动配置**：根据内存、延迟（100ms内/100-200ms/200ms以上）、带宽（100M-2G）三维度自动计算 BDP 推导最优缓冲区。

**手动配置**：直接选择缓冲区大小（12MB 到 128MB 共 6 档）。

**其他功能：**
- 限速设置（tc）：支持 200M/500M/780M/1G/2G 及自定义，OpenVZ 容器自动提示
- initcwnd 设置：10/50/100 及自定义，LXC 容器自动提示
- 备份/还原 sysctl 配置

**写入位置：** `/etc/sysctl.d/99-vps-bbr.conf`（不污染 `/etc/sysctl.conf`）

---

### 4. 防火墙管理

自动检测并支持 **ufw**（Debian/Ubuntu）和 **firewalld**（CentOS/Rocky）。

| 功能 | ufw | firewalld |
|------|-----|-----------|
| 开启/关闭 | ✓ | ✓ |
| 查看规则 | ✓ | ✓ |
| 添加端口 | ✓ | ✓ |
| 删除端口 | ✓（按编号循环） | ✓ |
| 拉黑 IP | ✓ | ✓（Rich Rule） |
| 放行 IP | ✓ | ✓（Rich Rule） |
| 删除 IP 规则 | ✓（循环模式） | ✓ |
| 一键放行常用端口 | SSH+80+443 | SSH+80+443 |
| 安装/更新 | ✓ | — |
| 卸载（含清理 iptables） | ✓ | ✓ |

未安装时引导选择安装 ufw 或 firewalld，安装后自动放行当前 SSH 端口、80、443。

---

### 5. DNS 优化

启动时自动检测 IPv4/IPv6 可用性，无 IPv6 的机器只显示 IPv4 DNS 选项。

| 选项 | IPv4 | IPv6 |
|------|------|------|
| Cloudflare | 1.1.1.1 / 1.0.0.1 | 2606:4700:4700::1111 |
| Google | 8.8.8.8 / 8.8.4.4 | 2001:4860:4860::8888 |
| 混合推荐 | CF + Google | 双栈 |
| 阿里云 | 223.5.5.5 / 223.6.6.6 | 2400:3200::1 |
| 腾讯 DNSpod | 119.29.29.29 / 183.60.83.19 | — |
| 114 DNS | 114.114.114.114 / 114.114.115.115 | — |
| 手动编辑 | nano `/etc/resolv.conf` | — |

---

### 6. Cloudflare DDNS

将动态公网 IP 自动同步到 Cloudflare DNS，适合家宽/动态 IP 场景。

**安装前需准备：**
1. 域名已托管到 Cloudflare（NS 指向 Cloudflare）
2. 创建 API Token：`Cloudflare 控制台 → My Profile → API Tokens → Create Token → Custom Token`，权限选 `Zone / DNS / Edit`
3. 准备好子域名（如 `home.example.com` 的 `home` 部分）

**支持配置项：**
- 记录模式：仅 IPv4 / IPv4+IPv6 双栈
- Cloudflare 代理（橙云）开关
- 自定义 TTL（默认 60 秒）

**运行机制：**
- crontab 每 5 分钟执行一次
- IP 未变化时仅记录日志，不请求 API
- IP 获取多源备用：`ipify.org → ifconfig.me → ip.sb`
- 日志保存在 `/var/log/ddns.log`

**菜单功能：**

| 功能 | 说明 |
|------|------|
| 手动立即更新 | 立即触发一次 IP 同步 |
| 查看日志 | 最近 20 条，支持实时跟踪 |
| 修改配置 | 更换域名/Token/模式 |
| 暂停/恢复 | 临时停用自动更新，不删除配置 |
| 卸载 | 移除脚本、crontab、Token 文件 |

---

### 7. 系统换源

| 系统 | 支持的源 |
|------|---------|
| Ubuntu | 阿里云 / 腾讯云 / 清华 / 中科大 / 官方源 |
| Debian | 阿里云 / 腾讯云 / 清华 / 中科大 / 官方源 |
| CentOS/Rocky | 阿里云 / 清华 / 默认源 |

换源前自动备份原始 sources.list，换源后自动执行 `apt update`。

---

### 8. IPv4/IPv6 配置

| 功能 | 说明 |
|------|------|
| 查看详细状态 | IP 地址、优先级策略、默认路由 |
| 设置 IPv4 优先 | 写入 `/etc/gai.conf`，立即生效 |
| 关闭 IPv6 | sysctl 持久化，立即生效 |
| 开启 IPv6 | 恢复 sysctl，等待 SLAAC 获取地址 |

---

### 9. Caddy 管理

自动 HTTPS 的现代 Web 服务器，自动申请和续期 Let's Encrypt 证书。

| 功能 | 说明 |
|------|------|
| 查看所有站点 | 列出 Caddyfile 中所有站点及转发规则 |
| 添加反向代理 | 域名 → 后端地址，自动判断 SSL 策略 |
| 添加静态网站 | 域名 → 本地目录，自动 HTTPS |
| 删除站点 | 按编号删除，自动重载 |
| SSL 证书状态 | 查看已申请的证书及到期时间 |
| 查看访问日志 | 彩色解析 JSON 日志，支持实时跟踪 |
| 编辑 Caddyfile | nano 直接编辑，保存后自动验证并重载 |
| 重载配置 | 验证语法后热重载，不中断服务 |
| 安装/更新 | apt 官方源 / apk / yum / 二进制回退 |
| 卸载 | 停止服务，保留配置文件 |

**带端口域名的 SSL 说明：**

`example.com:8443` 这类带端口的站点，Caddy 会自动为裸域名 `example.com` 申请证书并复用，无需额外配置。

---

### p. 端口转发（iptables NAT）

将外部访问的端口转发到本机另一个端口，例如访问 `16365` 自动转发到 `6365`。

| 功能 | 说明 |
|------|------|
| 添加规则 | 指定外部端口 → 目标端口，支持 TCP/UDP/双栈 |
| 删除规则 | 按编号删除，同步清理 OUTPUT 链 |
| 清空所有 | 清空 PREROUTING 和 OUTPUT 链 |

**持久化优先级：** `/etc/iptables/rules.v4` → `/etc/sysconfig/iptables` → `/etc/rc.local`（兜底）

LXC 容器权限不足时自动提示，不会报错卡住。

---

### t. 时间同步

| 功能 | 说明 |
|------|------|
| 强制同步时间 | 依次尝试 timesyncd → chrony → ntpdate → HTTP头兜底 |
| 设置北京时区 | Asia/Shanghai UTC+8，立即生效 |
| 一键同步+北京时区 | 两步合一 |
| 设置其他时区 | 含常用时区参考（东京/纽约/伦敦/巴黎等） |
| 开启 NTP 自动同步 | 自动检测 timesyncd/chrony，无则安装 chrony |

**自动适配：** 检测 `CanNTP` 状态，系统无 timesyncd 时自动安装 chrony，Debian 和 CentOS 的服务名（`chrony`/`chronyd`）自动区分。

---

### s. Swap 管理

| 功能 | 说明 |
|------|------|
| 创建/更换 Swap | 512MB/1G/2G/4G/自定义，自动写入 fstab |
| 删除 Swap | 按编号选择，同步从 fstab 移除 |
| 设置 Swappiness | 10（服务器推荐）/30/60（默认）/自定义 |

根据物理内存自动推荐合适的 Swap 大小。LXC/OpenVZ 容器自动提示可能不支持。

---

### m. 脚本管理

| 功能 | 说明 |
|------|------|
| 安装脚本 | 复制到 `/usr/local/bin/vps-tools`，创建 `v`/`V` 快捷命令 |
| 从 GitHub 更新 | 下载最新版，验证语法后覆盖安装，自动重启 |
| 删除本地脚本 | 移除脚本文件、快捷命令、shell 配置中的 alias |

**自动检测新版本：** 脚本启动时后台静默请求 GitHub，有新版本时主界面显示 🔔 提示，进 `m → 2` 一键更新。

**首次运行检测：** 未安装到本地时自动提示是否立即安装。

---

## 兼容性

| 特性 | 说明 |
|------|------|
| 发行版 | Debian / Ubuntu / CentOS / Alpine / OpenWrt |
| 架构 | x86_64 / aarch64 / armv7 |
| 服务管理 | systemd / OpenRC / SysV init |
| 容器 | KVM / LXC / OpenVZ（功能有限制时自动提示） |
| 终端 | 标准终端 / dumb 终端（OpenWrt/tmux，使用 `safe_clear` 避免报错） |
| Shell | bash / BusyBox ash（mktemp 用 PID 替代 XXXXXX 后缀） |

---

## 关键文件路径

| 文件 | 说明 |
|------|------|
| `/usr/local/bin/vps-tools` | 本地脚本安装路径 |
| `/usr/local/bin/v` | 快捷命令（软链接） |
| `/etc/sysctl.d/99-vps-bbr.conf` | BBR TCP 调优配置 |
| `/root/.cf_token` | Cloudflare API Token（权限 600） |
| `/root/.cf_zone` | DDNS 域名/模式/TTL 配置 |
| `/root/ddns.sh` | DDNS 执行脚本 |
| `/var/log/ddns.log` | DDNS 运行日志 |
| `/etc/fail2ban/jail.local` | Fail2ban 用户配置 |
| `/etc/caddy/Caddyfile` | Caddy 站点配置 |

---

## 开源地址

```
https://github.com/chnnic/SSH-Hardening
```

```bash
# 一行安装
bash <(curl -fsSL https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh)
```
