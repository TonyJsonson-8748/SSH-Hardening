# VPS 开荒脚本 V3.8.2

> **银趴火山帮** 出品 · SSH · BBR · DDNS · Caddy · Firewall · NFT 转发

一键式 VPS 初始化与管理工具，覆盖安全加固、网络调优、服务部署、端口转发全流程。支持 Debian / Ubuntu / CentOS / Alpine / OpenWrt 等主流系统。

> **运行依赖：** 脚本需 **bash** 运行（使用了数组 / `[[ ]]` / here-string 等特性）。Debian/Ubuntu/CentOS 默认自带；**Alpine 需 `apk add bash`，OpenWrt 需 `opkg install bash`**。脚本头部带解释器守卫：非 bash 环境会自动尝试切到 bash，缺失时给出清晰安装提示而非报一堆语法错。

---

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh)
```

**安装到本地后用快捷键 `v` / `V` 呼出：**

进入脚本 → `m) 脚本管理` → `1) 安装脚本 + 设置快捷键`

之后任意终端输入 `v` 即可启动。快捷键基于 `/usr/local/bin/` 软链接，不会污染 alias，与其他脚本（如 `volss`）完全隔离。

---

## 主界面

```
    ______  _______  ___    ____  ______   ____  ____  _____
   /  _/  |/  / __ \/   |  / __ \/_  __/  / __ \/ __ \/ ___/
   ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  VPS 开荒脚本  V3.8.2 · 银趴火山帮

  ◆ 系统概览
  ● SSH  22 · 1 公钥          ● 认证  仅密钥
  ● BBR  bbr · 无限速        ● Fail2ban  运行中
  ● 防火墙  ufw active       ● Caddy  运行中
  ● DDNS  运行中             ● 时间  16:30:00

  ◆ 安全与网络
    1  SSH 工具集              2  Fail2ban 管理
    3  BBR TCP 调优            4  防火墙管理
    5  DNS 优化                6  Cloudflare DDNS

  ◆ 系统与服务
    7  系统换源                8  IPv4 / IPv6
    9  Caddy 管理              n  NFT 转发
    t  时间与时区              s  Swap 管理
    h  安全与诊断              m  脚本管理
    0  退出脚本
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 功能详解

### 1. SSH 工具集

| 功能 | 说明 |
|------|------|
| 查看已有公钥 | 列出所有已授权公钥（支持 ed25519/rsa/ecdsa/sk-ssh/sk-ecdsa/dss） |
| 添加公钥 | 粘贴公钥添加，自动去重 |
| 删除公钥 | 按编号删除，匹配公钥主体不受备注/末尾空格影响 |
| 生成密钥对 | Ed25519 或 RSA-4096，可直接加入服务器（去重） |
| 设置登录方式 | 仅密钥 / 密码+密钥 / 仅密码 |
| 修改 SSH 端口 | 自动备份、语法验证、防火墙同步放行 |

**root 用户固定使用 `/root/.ssh/authorized_keys`**，兼容系统预装公钥。

---

### 2. Fail2ban 管理

自动封禁 SSH 暴力破解 IP。安装时自动检测 backend，支持 `python3-systemd` / `rsyslog` / `auto` 多种方式。

| 功能 | 说明 |
|------|------|
| 查看封禁 IP | 当前所有被封禁的 IP |
| 手动解封 | 立即解封指定 IP |
| 实时日志 | 彩色显示（UTF-8 兼容） |
| 基础参数配置 | bantime / findtime / maxretry / 监控端口 |
| 编辑配置 | 自动选择编辑器（nano → vi → vim） |
| 安装 / 更新 / 卸载 | 一键操作 |

**快速预设：**

| 预设 | bantime | findtime | maxretry |
|------|---------|----------|----------|
| 严格 | 1 天 | 10 分钟 | 3 |
| 标准 | 1 小时 | 10 分钟 | 5 |
| 宽松 | 30 分钟 | 5 分钟 | 10 |
| 永久 | 永久 | 10 分钟 | 3 |

---

### 3. BBR TCP 调优

**智能向导（推荐）** — 自动检测内存推荐预设：

| 内存 | 推荐 |
|------|------|
| < 768 MB | `latency` 低延迟 |
| < 4 GB | `balanced` 均衡 |
| ≥ 4 GB | `throughput` 高吞吐 |

**三种预设：**

| 预设 | 缓冲区 | 适用 |
|------|--------|------|
| `latency` | 32 MB | SSH / 游戏 / 远程桌面 |
| `balanced` | 16-64 MB（按内存动态） | 网页 / 代理 / 日常 |
| `throughput` | 64-512 MB（按内存动态） | 万兆 / 跨洋 |

**自动配置（BDP 三维计算）：**
- 内存：512MB / 1G / 2G / 4G / 8G / 16G+
- 延迟：100ms 以内 / 100-200ms / 200ms 以上
- 带宽：100M / 200M / 500M / 1G / 2G / 5G / 10G

**手动配置（两步式：选用途 → 选缓冲）：** 12 / 16 / 20 / **32** / 40 / 64 / 128 / 256 / 512 / 1024 MB 共 10 档（新增 32MB 为 1G 跨境甜点区）

**安全保护：**
- 缓冲区超过物理内存一半自动降级或警告
- 无 sysctl 写入权限（无特权容器）自动检测并提示
- 内核 BBR 支持检测（kernel ≥ 4.9）
- 应用前自动备份旧 sysctl 配置
- 切换预设时检测并复位上一场景遗留的转发/conntrack 残留键（ip_forward 单独警告）
- 逐行 `sysctl -w` 应用，跳过 Alpine 等内核不支持的参数（如 `default_qdisc`）

**其他功能：**
- tc 限速（200M / 500M / 780M / 1G / 2G / 自定义）：`htb` 聚合整形 + `fq` 叶子保留 BBR pacing，burst 随速率缩放（避免高速率跑不满线）
- initcwnd（10 / 50 / 100 / 自定义）
- 备份 / 还原 sysctl（按时间戳）

**代理专项参数：**
- 通用核心含 UDP 缓冲（`udp_rmem_min/wmem_min`），优化 QUIC / Hysteria2 / TUIC
- 场景预设（中转/落地）额外含扩大出站端口范围、`tcp_max_tw_buckets`、`fs.file-max`，防高并发端口/fd 耗尽
- 应用场景预设后自动检测代理 service 的 `LimitNOFILE`，偏低时询问写入 drop-in

**写入位置：** `/etc/sysctl.d/99-vps-bbr.conf`（不污染主配置）

---

### 4. 防火墙管理

自动检测 **ufw**（Debian/Ubuntu）和 **firewalld**（CentOS/Rocky）。

| 功能 | 说明 |
|------|------|
| 开启 / 关闭 | 一键切换 |
| 查看规则 | 列出所有规则 |
| 添加 / 删除端口 | 支持端口段，按编号循环删除 |
| 拉黑 / 放行 IP | ufw deny / firewalld rich rule |
| 一键放行常用端口 | SSH + 80 + 443 |
| 安装 / 卸载 | 完整安装 + iptables 残留清理 |

**安全保护：** 卸载防火墙前显示警告（清空规则会暴露主机，2 秒确认延迟）

---

### 5. DNS 优化

启动时自动检测 IPv4/IPv6，无 IPv6 的机器只显示 IPv4 选项。

| 选项 | IPv4 | IPv6 |
|------|------|------|
| Cloudflare | 1.1.1.1 / 1.0.0.1 | 2606:4700:4700::1111 |
| Google | 8.8.8.8 / 8.8.4.4 | 2001:4860:4860::8888 |
| 混合推荐 | CF + Google | 双栈 |
| 阿里云 | 223.5.5.5 / 223.6.6.6 | 2400:3200::1 |
| 腾讯 DNSpod | 119.29.29.29 / 183.60.83.19 | — |
| 114 DNS | 114.114.114.114 / 114.114.115.115 | — |
| 手动编辑 | 自动选择编辑器 | — |

---

### 6. Cloudflare DDNS

将动态公网 IP 自动同步到 Cloudflare DNS。

**安装前准备：**
1. 域名托管到 Cloudflare
2. 创建 API Token：`Zone / DNS / Edit` 权限
3. 准备子域名

**支持配置：**
- 记录模式：仅 IPv4 / IPv4+IPv6 双栈
- Cloudflare 代理（橙云）开关
- 自定义 TTL（默认 60 秒）

**运行机制：**
- crontab 每 5 分钟执行
- IP 未变化时仅记录日志，不请求 API
- IP 多源备用：`ipify.org → ifconfig.me → ip.sb`
- **IPv4 格式严格校验**：纯 IPv6 机器自动识别不会误发
- **二次校验**：检测到 IP 变化时再查询一次，防止误推
- **日志自动轮转**：超过 500 行自动只保留最近 500 条
- 日志：`/var/log/ddns.log`

**Telegram 通知：**

IP 真实变化时推送通知，实时读取 `/root/.cf_tg`，兼容 crontab 环境（PATH 注入）。

**通知格式：**
```
🌐 DDNS IP 已更新
域名：home.example.com
类型：A
旧IP：1.2.3.4
新IP：5.6.7.8
时间：2026-05-22 16:30:00
```

**菜单：**

| 功能 | 说明 |
|------|------|
| 手动立即更新 | 立即触发同步 |
| 查看日志 | 彩色显示 + 实时跟踪 + UTF-8 完整查看 |
| 修改配置 | 更换域名 / Token / 模式 |
| 暂停 / 恢复 | 临时停用不删除配置 |
| 卸载 | 完整清理 |
| Telegram 通知 | 配置 Bot + Chat ID，发测试消息 |

**状态显示：**
- `运行中` — crontab 正常
- `已停止（cron任务未设置）` — 有 ddns.sh 但 crontab 未写入
- `已停止（cron未安装）` — 系统无 cron，自动安装入口

---

### 7. 系统换源

| 系统 | 支持的源 |
|------|---------|
| Ubuntu | 阿里 / 腾讯 / 清华 / 中科大 / 官方 |
| Debian | 阿里 / 腾讯 / 清华 / 中科大 / 官方 |
| CentOS / Rocky | 阿里 / 清华 / 默认 |

换源前自动备份，换源后自动 `apt update`。

---

### 8. IPv4/IPv6 配置

| 功能 | 说明 |
|------|------|
| 查看详细状态 | IP 地址 / 优先级 / 默认路由 |
| 设置 IPv4 优先 | 写入 `/etc/gai.conf` 立即生效 |
| 设置 IPv6 优先 | 移除 IPv4 优先规则，恢复系统默认 IPv6 优先 |
| 关闭 IPv6 | sysctl 持久化 |
| 开启 IPv6 | 恢复 sysctl + 等待 SLAAC |

---

### 9. Caddy 管理

自动 HTTPS 的现代 Web 服务器。

| 功能 | 说明 |
|------|------|
| 查看所有站点 | 列出 Caddyfile 中所有站点 |
| 添加反向代理 | 域名 → 后端，自动判断 SSL 策略 |
| 添加静态网站 | 域名 → 本地目录，自动 HTTPS |
| 删除站点 | 按编号删除，自动重载 |
| SSL 证书状态 | 查看证书及到期时间 |
| 查看访问日志 | 彩色解析 JSON，实时跟踪 |
| 编辑 Caddyfile | 自动选择编辑器，保存后验证并重载 |
| 重载 / 安装 / 卸载 | 完整管理 |

---

### n. NFT 转发管理（端口转发 / DDNS / 访问控制）

**V3.4.0 新增模块**，基于 **nftables** 的现代端口转发，比旧版 iptables NAT 更强大、规则可持久化。

**菜单结构：**
```
  nftables : 已安装    规则数: 3
  访问控制 : 关闭
  DDNS 定时刷新 : 运行中
  ──────────────────────────────────────
  当前规则：
  [1] [ipv4] [单端口] 0.0.0.0:443 → 1.2.3.4:443
  [2] [ipv4] [端口段1:1] 0.0.0.0:10000-10100 → 5.6.7.8:10000-10100
  [3] [ipv6] [单端口] [::]:80 → home.example.com:8080 (2001:db8::1)
  ──────────────────────────────────────
  1) 添加单端口转发     2) 添加端口段转发
  3) 查看所有规则       4) 删除规则
  5) 清空所有规则
  ──────────────────────────────────────
  6) 立即刷新 DDNS
  7) 启用 DDNS 自动刷新
  8) 访问控制（白/黑名单）
```

**核心功能：**

| 功能 | 说明 |
|------|------|
| **单端口转发** | 一个监听端口转发到一个目标端口 |
| **端口段 1:1 映射** | `10000-10100` → 目标 `10000-10100` |
| **端口段偏移映射** | `10000-10100` → 目标 `20000-20100` |
| **双栈支持** | 同一菜单管理 IPv4 + IPv6 规则 |
| **域名目标** | 支持目标填域名，自动 DNS 解析 |

**DDNS 域名目标：**
- 添加规则时目标可填域名（如 `home.example.com`）
- 脚本自动解析为 IP 并记录
- **立即刷新** — 重新解析所有域名目标，IP 变化时更新规则
- **自动刷新** — systemd timer 定时执行（10s ~ 24h 任意间隔）
- 解析失败保留旧 IP，避免规则丢失

**访问控制：**

| 模式 | 行为 |
|------|------|
| 白名单 | 仅允许名单内 IP/CIDR 访问转发端口 |
| 黑名单 | 拒绝名单内 IP/CIDR 访问 |
| 关闭 | 不限制 |

支持 IPv4/IPv6 + CIDR 网段（如 `1.2.3.0/24`、`2001:db8::/32`）。

**关键安全防护：**
- 启用白名单时自动检测 `$SSH_CONNECTION` 当前 SSH 来源 IP
- 不包含时主动询问是否自动加入，**防止自我封锁**
- 仅影响 NFT 转发端口，不影响 SSH 等其他服务

**持久化与跨发行版：**
- 规则数据：`/etc/nft-port-forward/rules.db`
- 访问控制：`/etc/nft-port-forward/access.conf`
- nftables 配置：`/etc/nftables.conf`（脚本托管，自动校验语法）
- 自动安装 nftables（apt / apk / yum / dnf）
- 自动开启 IP 转发
- 服务自启：systemd / OpenRC 双支持

---

### t. 时间同步

| 功能 | 说明 |
|------|------|
| 强制同步时间 | timesyncd → chrony → ntpdate → HTTP 头兜底 |
| 设置北京时区 | Asia/Shanghai UTC+8 |
| 一键同步+北京时区 | 两步合一 |
| 其他时区 | 含常用时区参考 |
| 开启 NTP 自动同步 | timesyncd / chrony 自动选择 |

HTTP 时间同步显示**中间人风险警告**，建议安装 chrony。

---

### s. Swap 管理

| 功能 | 说明 |
|------|------|
| 创建 / 更换 Swap | 512MB / 1G / 2G / 4G / 自定义 |
| 删除 Swap | 按编号删除，同步 fstab |
| Swappiness | 10 / 30 / 60 / 自定义 |

LXC / OpenVZ 容器自动提示可能不支持。

---

### h. 安全与诊断工具箱

| 功能 | 说明 |
|------|------|
| 系统安全体检 | 检查 SSH 登录策略、配置语法、防火墙、Fail2ban、UID 0 账户、监听端口及待更新软件包 |
| 登录安全日志 | 查看成功/失败登录、当前会话、SSH 日志和 Fail2ban 状态 |
| 网络诊断 | 地址、路由、DNS、Ping、公网出口和路径 MTU 检测 |
| 配置备份恢复 | 统一备份 SSH、防火墙、DNS、sysctl、Caddy、DDNS 和 NFT 配置 |
| 操作记录 | 将关键操作、来源 IP 和结果写入 `/var/log/vps-tools-audit.log` |
| 系统资源健康 | CPU、负载、内存、磁盘、inode、连接、进程及失败服务 |
| 系统更新管理 | 检查更新、安全更新、完整更新、自动安全更新和缓存清理 |

SSH、防火墙、DNS、IP 优先级及 IPv6 修改会启动 180 秒防断联保护。用户未确认新连接正常时，脚本自动恢复修改前配置和服务状态。

高风险配置修改会先显示变更计划或逐行差异；配置备份默认保留最近 20 份，可通过环境变量 `VPS_BACKUP_KEEP` 调整。

DNS 设置会自动识别 `systemd-resolved`、NetworkManager、resolvconf 或静态 `/etc/resolv.conf`，使用对应后端持久化配置。

---

### m. 脚本管理

| 功能 | 说明 |
|------|------|
| 安装 + 设置快捷键 | `/usr/local/bin/vps-tools` + `v` / `V` 软链接 |
| 从 GitHub 更新 | SHA256 + Bash 语法校验、保存旧版本、覆盖并自动重启 |
| 回滚脚本版本 | 从 `/var/lib/vps-tools/versions` 选择更新前版本恢复 |
| 删除本地脚本 | 仅删除指向本脚本的软链接，不影响其他脚本 |

**快捷键设计（V3.0.4+）：**
- 只用 `/usr/local/bin/v` 和 `/V` 软链接
- **不写 alias**，避免拦截 `v` 开头的其他命令（如 `volss`）
- 更新时自动清理历史遗留 alias

**自动检测新版本：** 后台请求 GitHub，新版本时主界面显示 🔔 提示。

---

## 安全增强

| 项 | 说明 |
|----|------|
| DDNS 脚本权限 | `chmod 700`，仅 root 可读（含 CF Token） |
| 防火墙卸载警告 | 清空规则会暴露主机，2 秒延迟 + 警告 |
| pf_flush 警告 | 清空所有 NAT 规则会影响其他应用 |
| HTTP 时间同步 | 标注未经认证，可被中间人伪造 |
| 内核支持检测 | BBR 应用前检测内核版本和模块 |
| 容器权限检测 | 自动识别无特权容器，sysctl 操作受限时友好提示 |
| 防断联保护 | 高风险网络修改 180 秒未确认自动回滚 |
| 更新完整性 | 下载脚本必须匹配仓库中的 SHA256 校验文件 |

---

## 兼容性

| 特性 | 说明 |
|------|------|
| 发行版 | Debian / Ubuntu / CentOS / Alpine / OpenWrt |
| 架构 | x86_64 / aarch64 / armv7 |
| 服务管理 | systemd / OpenRC / SysV init |
| 容器 | KVM / LXC / OpenVZ / 无特权容器 |
| 终端 | 36-76 列响应式布局；标准 / dumb / tmux / OpenWrt；支持 `NO_COLOR=1` |
| Shell | **bash 必需**（Alpine: `apk add bash`，OpenWrt: `opkg install bash`；非 bash 环境自动切换 / fail-fast 提示） |

---

## 关键文件路径

| 文件 | 说明 |
|------|------|
| `/usr/local/bin/vps-tools` | 主脚本 |
| `/usr/local/bin/v` `/V` | 快捷命令（软链接） |
| `/var/lib/vps-tools/backups` | 统一配置备份与防断联快照 |
| `/var/lib/vps-tools/versions` | 更新前的历史脚本版本 |
| `/var/log/vps-tools-audit.log` | 脚本操作审计日志（600） |
| `SSH-Hardening.sh.sha256` | 自更新完整性校验值 |
| `/etc/sysctl.d/99-vps-bbr.conf` | BBR TCP 配置 |
| `/etc/nftables.conf` | NFT 转发配置（脚本托管） |
| `/etc/nft-port-forward/rules.db` | NFT 转发规则数据库 |
| `/etc/nft-port-forward/access.conf` | NFT 访问控制配置 |
| `/etc/systemd/system/nftpf-ddns.timer` | NFT DDNS 自动刷新 timer |
| `/root/.cf_token` | Cloudflare API Token（600） |
| `/root/.cf_zone` | DDNS 域名/模式/TTL 配置 |
| `/root/.cf_tg` | Telegram Bot 配置（600） |
| `/root/ddns.sh` | DDNS 执行脚本（700） |
| `/var/log/ddns.log` | DDNS 日志（自动轮转 500 行） |
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

### 开发与构建

仓库源码位于 `src/lib/` 和 `src/modules/`。用户安装的 `SSH-Hardening.sh` 是由模块生成的完整单文件，运行时不下载任何模块：

```bash
./build.sh          # 生成单文件并刷新 SHA256
./build.sh --check  # 检查发行文件是否与模块源码一致
tests/smoke.sh
tests/fault-injection.sh
```

GitHub Actions 还会在 Debian、Ubuntu、Alpine、Rocky Linux 容器中加载生成脚本并执行冒烟测试。

---

## 版本沿革（近期）

| 版本 | 主要变更 |
|------|---------|
| **V3.8.2** | 统一剩余子页面：BBR 多级向导、Fail2ban 参数页、Swap、换源、DNS、日志、NFT 访问控制和安装向导全面接入响应式菜单、统一输入提示与返回行为 |
| **V3.8.1** | 全面重构终端 UI：响应式宽度、窄屏单列/宽屏双列、统一状态仪表盘与操作提示、紧凑页面标题、主要模块菜单规范化，并支持 `NO_COLOR` 与非交互终端无 ANSI 输出 |
| **V3.8.0** | 源码拆分为 core 和功能模块，由 `build.sh` 生成单文件发行版；新增 Debian/Ubuntu/Alpine/Rocky 冒烟测试与故障注入测试；新增备份保留策略、配置变更预览、资源健康检查和系统更新管理 |
| **V3.7.0** | 新增安全体检、登录安全日志、网络诊断、统一配置备份恢复、操作审计；SSH/防火墙/DNS/IP 修改加入 180 秒防断联回滚；DNS 自动适配 resolved/NetworkManager/resolvconf；脚本更新增加 SHA256 校验、旧版本留存和一键回滚 |
| **V3.6.3** | IPv4/IPv6 配置菜单新增“设置 IPv6 优先”，可移除 `/etc/gai.conf` 中的 IPv4 优先规则并恢复系统默认地址选择策略 |
| **V3.6.2** | BBR 模块增强：sysctl 权限探测不再改变 TCP 参数；tc 限速服务运行时动态识别 `tc` 路径和默认网卡；不支持的 sysctl 参数会在持久化文件中注释；Alpine 内核包安装改为确认后执行；新增 BBR 诊断入口 |
| **V3.6.1** | 修复删除最后一个 SSH 公钥不生效；DDNS 在 `/var/log/ddns.log` 不可写时正确使用备用日志路径；nftables 配置应用失败时不再误报成功；BBR `initcwnd` 支持无网关默认路由 |
| **V3.6.0** | Fail2ban 修正：jail 加 `mode = aggressive`（纯公钥机/禁密码下也能抓扫描者并封禁，解决 `Total failed` 恒为 0）；`journalmatch` 显式双服务名 `ssh.service + sshd.service`（兼容 Debian/RedHat，不改系统 filter）；`jail.local` 已存在由「跳过」改为「备份后重写」（否则脚本更新的配置永不生效） |
| **V3.5.9** | 安全加固一批：SSH 改端口/配置失败**自动回滚**到备份；改端口**延后删旧端口**（先确认新端口可连，防锁死）；防火墙卸载**不再 flush 全表/改默认策略**（只删本脚本规则，避免裸奔与误删 NFT/代理规则）；DDNS IPv4 **严格校验**每段 0-255；服务操作统一 `svc_start/stop/restart` 封装（OpenRC/sysvinit 兼容）；默认网卡改用 `ip route get`；Caddy 配置**临时验证通过才写入**（失败自动还原） |
| **V3.5.8** | 修复 `bbr-tune.sh` 独立版缺失 4 个辅助函数（`ensure_conntrack_module` / `svc_daemon_reload` / `svc_enable` / `svc_disable`，提取时遗漏），独立运行限速 / 场景预设 / initcwnd 不再中断（主脚本不受影响） |
| **V3.5.7** | DDNS 状态区增加「最后一次 IP 变更时间 + 新旧 IP」显示（记录于 `/root/.cf_last_change`，PUT 成功时写入，卸载时清理） |
| **V3.5.6** | 新增 UDP 缓冲（`udp_rmem_min/wmem_min`，优化 QUIC/Hysteria2/TUIC）；场景预设加扩大出站端口范围 + `tcp_max_tw_buckets` + `fs.file-max`，防高并发端口/fd 耗尽；应用场景预设后自动检测代理 service 的 `LimitNOFILE`，偏低时询问写入 drop-in |
| **V3.5.5** | BBR 限速改 htb 整形 + fq pacing（多队列网卡保留 BBR pacing，旧 tbf 会废 pacing）；burst 随速率缩放；切换预设复位残留场景键；新增 32MB 缓冲档；修 BDP 双截断；line_landing ADV_WIN 1→2；UI 全面美化对齐（统一 menu_div/menu_group/menu_item，分隔线对齐 40 宽） |
| **V3.5.4** | bash-first：脚本头部加解释器守卫（非 bash 自动切换 / fail-fast 提示）；修复 DDNS 自动创建 A/AAAA 记录时内联 JSON 引号拼接错误（改用 printf 构建，原写法发出非法 JSON 导致建记录失败） |
| V3.5.3 | NFT 新增规则修改功能（逐项交互修改，应用失败自动回滚） |
| V3.5.2 | BBR 手动配置加场景选择前置层（中转/落地/线路落地/通用） |
| V3.5.1 | 场景预设注入转发参数（5 项）+ 仅中转追加 conntrack（3 项），自动 modprobe nf_conntrack |
| V3.5.0 | 智能向导菜单分组，新增 3 个场景化预设（relay/landing/line_landing） |
| V3.4.5 | DDNS 日志查看内部循环，按 0 立即返回 |
| V3.4.4 | 新增 iptables 本地端口转发子菜单 |
| V3.4.3 | NFT 菜单加安装/卸载，未安装时只显安装入口 |
| V3.4.2 | 修复 grep -c 返回 `0\n0` 导致 integer expression 报错 |
| V3.4.1 | BBR sysctl 精简到 15 个核心参数，按 4 组分类 |
| **V3.4.0** | 新增 NFT 转发管理模块（替代 iptables NAT 端口转发 + 整合入站白名单） |
| V3.3.5 | 清理 7 个死代码函数 + 提取重复的 iptables 清理逻辑 |
| V3.3.4 | DDNS 二次校验，避免查询失败误推 Telegram 通知 |
| V3.3.3 | less / 日志显示强制 UTF-8，避免中文乱码 |
| V3.3.2 | DDNS 日志按行数限制（500 条） |
| V3.2.5 | BBR 支持万兆 / 4G+ 内存（256/512/1024MB 缓冲区） |
| V3.2.3 | 修复 DDNS 模块定义两遍导致所有修复失效的 Bug |
| V3.2.1 | 无特权容器 sysctl 权限检测 |
| V3.2.0 | BBR sysctl 逐行写入，跳过 Alpine 不支持的参数 |
| V3.1.6 | Alpine ash 兼容（去除 bash 专属语法） |
| V3.0.4 | 快捷键改用纯软链接，不写 alias，避免冲突其他脚本 |
| V3.0.0 | 主菜单与 fork 同步，整合 BBR 智能向导 + DDNS 双栈 + Telegram |
