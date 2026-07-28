# VPS 开荒脚本 V3.50.2

> **银趴火山帮** 出品 · SSH · BBR · DDNS · Caddy · Firewall · NFT 转发

一键式 VPS 初始化与管理工具，覆盖安全加固、网络调优、服务部署、端口转发全流程。支持 Debian / Ubuntu / CentOS / Alpine / OpenWrt 等主流系统。

> 当前长期维护仓库：[TonyJsonson-8748/SSH-Hardening](https://github.com/TonyJsonson-8748/SSH-Hardening)；上游原仓库：[chnnic/SSH-Hardening](https://github.com/chnnic/SSH-Hardening)。

> **运行依赖：** 脚本需 **bash** 运行（使用了数组 / `[[ ]]` / here-string 等特性）。Debian/Ubuntu/CentOS 默认自带；**Alpine 需 `apk add bash`，OpenWrt 需 `opkg install bash`**。脚本头部带解释器守卫：非 bash 环境会自动尝试切到 bash，缺失时给出清晰安装提示而非报一堆语法错。

---

## 快速开始

root 用户：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/refs/heads/main/SSH-Hardening.sh)
```

普通用户且具有 sudo 权限：

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/refs/heads/main/SSH-Hardening.sh)'
```

脚本涉及系统账号、SSH、防火墙和服务配置，除 `--help` 外必须使用 root 权限。本地脚本由普通用户启动时会询问是否通过 sudo/doas 重新运行；如果当前账号没有提权权限，会给出切换 root 的明确提示。

### 离线安装包

适合不能访问 GitHub 的 VPS。先在一台可以访问 GitHub 的电脑或跳板机打开本仓库的 [Releases 页面](https://github.com/TonyJsonson-8748/SSH-Hardening/releases)，下载版本一致的 `vps-tools-offline-V*.tar.gz` 和 `.sha256` 文件。若该版本尚未发布 Release，也可以克隆本仓库后自行构建：

```bash
git clone https://github.com/TonyJsonson-8748/SSH-Hardening.git
cd SSH-Hardening
./build-offline-package.sh
```

然后通过 `scp`、SFTP 或 WinSCP 将压缩包和外部校验文件传到 VPS。Linux/macOS 示例：

```bash
scp dist/vps-tools-offline-V*.tar.gz* root@你的VPS地址:/root/
```

登录 VPS 后离线安装：

```bash
cd /root
sha256sum -c vps-tools-offline-V*.tar.gz.sha256
tar -xzf vps-tools-offline-V*.tar.gz
cd vps-tools-offline-V*
bash install.sh
v
```

安装阶段不会访问网络。安装包包含完整脚本、内部 SHA256 和独立安装器；不会覆盖其他程序已经占用的 `v` / `V` 命令。安装第三方软件、DDNS、自更新等功能仍需要相应网络连接。

开发者也可以从仓库源码自行构建同样的安装包：

```bash
./build-offline-package.sh
```

## 命令行合集

所有入口都可以直接从 GitHub 调用，也可以在安装到本地后用 `v --命令` 调用。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/refs/heads/main/SSH-Hardening.sh) --help
```

| 命令 | 功能 |
|------|------|
| `--ssh-menu` | SSH 工具集 |
| `--user-menu` | 用户管理（账号、密码与管理员权限） |
| `--fail2ban-menu` | Fail2ban 管理 |
| `--bbr-menu` | BBR TCP 调优 |
| `--firewall-menu` | 防火墙管理 |
| `--dns-menu` | DNS 优化 |
| `--ddns-menu` | DDNS 菜单（Cloudflare / 华为云 DNS） |
| `--ddns-install` | 安装 / 配置 DDNS |
| `--ddns-run` | 立即更新 DDNS |
| `--ddns-status` | 查看 DDNS 状态 |
| `--ddns-log` | 查看 DDNS 日志 |
| `--ddns-link` | 用当前 IPv4 / IPv6 DDNS 域名替换代理分享链接地址 |
| `--mirror-menu` | 系统换源 |
| `--ip-menu` | IPv4 / IPv6 配置 |
| `--caddy-menu` | Caddy 管理 |
| `--nft-menu` | NFT 转发 |
| `--time-menu` | 时间与时区 |
| `--https-time-sync` | 立即执行 HTTPS 时间同步 |
| `--swap-menu` | Swap 管理 |
| `--system-toolbox-menu` | 安全与诊断 |
| `--stun-test` | STUN、多端口 UDP 与 NAT 类型检测 |
| `--hostname-menu` | 修改系统 hostname |
| `--docker-menu` | Docker 管理 |
| `--software-menu` | 软件与重装 |
| `--self-manage-menu` | 脚本管理 |
| `--monitor-home` | 监控告警中心 |
| `--monitor-config` | 监控告警配置 |
| `--config-backup-menu` | 配置备份 |
| `--config-transfer-menu` | 配置迁移 |
| `--rollback-center-menu` | 回滚中心 |
| `--monitor-alert` | 监控告警定时任务入口 |
| `--nft-refresh-ddns` | NFT DDNS 刷新内部入口 |

**安装到本地后用快捷键 `v` / `V` 呼出：**

进入脚本 → `m) 脚本管理` → `1) 安装脚本 + 设置快捷键`

之后任意终端输入 `v` 即可启动。快捷键基于 `/usr/local/bin/` 软链接，不会污染 alias，与其他脚本（如 `volss`）完全隔离。

---

## 主界面

```
██╗███╗   ███╗██████╗  █████╗ ██████╗ ████████╗     ██████╗ ██████╗ ███████╗
██║████╗ ████║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝    ██╔═══██╗██╔══██╗██╔════╝
██║██╔████╔██║██████╔╝███████║██████╔╝   ██║       ██║   ██║██████╔╝███████╗
██║██║╚██╔╝██║██╔═══╝ ██╔══██║██╔══██╗   ██║       ██║   ██║██╔═══╝ ╚════██║
██║██║ ╚═╝ ██║██║     ██║  ██║██║  ██║   ██║       ╚██████╔╝██║     ███████║
╚═╝╚═╝     ╚═╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝        ╚═════╝ ╚═╝     ╚══════╝

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  VPS TOOLS  ·  V3.50.2
  VPS 开荒脚本 · 银趴火山帮
────────────────────────────────────────────────────────────────
  SSH · BBR · DDNS · Caddy · Firewall · NFT · Monitor

  ◆ 系统概览
  ● SSH  22 · 1 公钥          ● 认证  仅密钥
  ● BBR  bbr · 无限速        ● Fail2ban  运行中
  ● 防火墙  ufw active       ● Caddy  运行中
  ● DDNS  运行中             ● Docker  运行中
  ● 时间  16:30:00

  ◆ 安全与网络
    1  SSH 工具集              2  Fail2ban 管理
    3  BBR TCP 调优            4  防火墙管理
    5  DNS 优化                6  DDNS

  ◆ 系统与服务
    7  系统换源                8  IPv4 / IPv6
    9  Caddy 管理              n  NFT 转发
    t  时间与时区              s  Swap 管理
    h  安全与诊断              a  软件与重装
    d  Docker 管理             u  用户管理
    m  脚本管理                g  监控告警中心
    0  退出脚本
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 功能详解

### 1. SSH 工具集

| 功能 | 说明 |
|------|------|
| 查看指定用户公钥 | 从 root 和可登录普通用户中选择目标，解析其全部实际生效的 `AuthorizedKeysFile`，列出公钥类型、指纹、备注、授权选项及文件行号 |
| 为指定用户添加公钥 | 从 root 和可登录普通用户中选择目标，解析该用户实际生效的 `AuthorizedKeysFile`，使用 `ssh-keygen` 验证格式后写入并自动去重；用户名或公钥直接回车均可取消 |
| 删除指定用户公钥 | 只删除所选文件中的指定公钥行；删除前预演全机登录路径，必须保留可登录的 root，或可登录且拥有完整 sudo/doas root 权限的用户，并提供独立备份与 180 秒自动回滚 |
| 生成密钥对 | Ed25519 或 RSA-4096；生成后默认加入 root，也可指定其他可登录用户，或仅复制密钥而不写入服务器；统一按实际 `AuthorizedKeysFile` 校验、去重并设置属主和权限 |
| 设置登录方式 | 仅密钥 / 密码+密钥 / 仅密码 / 严格模式 |
| 修改 SSH 端口 | 自动备份、语法验证、防火墙放行，并同步 Fail2ban 监控端口 |
| 撤销指定用户 SSH 登录权限 | 通过 `DenyUsers` 禁止目标用户的新 SSH 登录；应用前综合密码、密钥、键盘交互、AuthenticationMethods、Allow/Deny、账号期限和 root 策略确认仍有备用登录及管理入口 |

查看、添加、删除以及“生成密钥对后添加”都会依据 `sshd -T -C` 解析目标用户实际生效的 `AuthorizedKeysFile`。生成密钥对后的目标用户名直接回车时默认使用 root，也可输入其他可登录用户；在是否添加时选择 `n`，或在用户名处输入 `0`，均只生成和显示密钥而不写入服务器。查看功能会标明密钥所在文件及物理行号；删除功能不会按公钥主体批量删除重复项，而是只删除本次选中的那一行。

**严格模式**会设置：

```text
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no
KbdInteractiveAuthentication no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
```

截图中每项配置的含义：

| 配置 | 严格模式中的作用 |
|------|------------------|
| `PasswordAuthentication no` | 关闭 SSH 密码认证，用户不能只凭账号密码登录 |
| `PubkeyAuthentication yes` | 启用 SSH 公钥认证 |
| `AuthenticationMethods publickey` | 明确要求认证流程必须完成公钥认证，避免其他已启用的认证方式成为替代入口 |
| `PermitRootLogin no` | 完全禁止 root 通过 SSH 远程登录，包括 root 密钥登录；日常应登录普通管理员账号后再提权 |
| `KbdInteractiveAuthentication no` | 关闭 PAM/验证码等键盘交互式认证入口，避免其退化成密码登录通道 |
| `MaxAuthTries 3` | 单次连接最多允许 3 次认证尝试，降低暴力尝试空间 |
| `ClientAliveInterval 300` | 连接空闲时，服务端每 300 秒向客户端发送一次存活探测 |
| `ClientAliveCountMax 2` | 连续 2 次存活探测没有响应后断开连接；结合上一项约为 10 分钟失联后清理会话，并非强制让正常响应的空闲客户端下线 |
| `X11Forwarding no` | 禁止通过 SSH 转发 X11 图形界面，减少不需要的攻击面 |

严格模式没有强制绕过入口。脚本只接受拥有完整 sudo/doas root 管理权限、可交互登录、未被 Allow/Deny 规则阻止，且存在格式有效、路径与权限安全、无前置限制选项公钥的非 root 用户。候选配置还必须同时通过 `sshd -t` 和按当前连接条件执行的 `sshd -T -C` 校验。应用后会启动 180 秒自动回滚；必须从新终端强制使用该用户的公钥成功登录，并输入用户名确认，才会取消回滚。

撤销用户登录同样先生成候选配置并验证。撤权后至少要保留一个其他可登录账号，并且剩余入口中必须有可登录的 root，或拥有完整 sudo/doas root 权限的可登录用户；只具备有限 sudo 命令的账号不计作恢复入口。否则脚本拒绝执行。应用后也必须从新终端验证所选备用账号，未确认时配置会自动恢复。

删除公钥采用同一管理入口标准，但会精确模拟“忽略所选公钥行”后的全机登录状态。即使还有普通用户能登录，只要没有可恢复 root 管理能力的入口，脚本仍会拒绝删除。通过预检后，脚本先备份原公钥文件，再原子替换目标文件并重新检查实际状态；必须在新终端验证选定的管理员账号及其 root 提权能力，未在 180 秒内确认时会自动恢复原文件。查看目标用户、删除成功、预检拒绝、写入失败、回滚和新会话确认都会写入审计日志，但不会记录公钥主体。

---

### 2. 用户管理

该模块只允许 root 执行，支持：

| 功能 | 说明 |
|------|------|
| 创建普通用户 | 创建主目录、选择可用登录 Shell、设置隐藏输入的登录密码，不授予管理权限 |
| 创建管理员用户 | 自动检测或安装 sudo，加入系统原生 `sudo` / `wheel` 组，并写入独立 sudoers 规则 |
| 查看用户列表 | 展示 root 和普通 UID 范围内的账号、UID、主目录、Shell，并按用户组、托管规则及 sudo 实际权限识别管理员类型 |
| 修改用户密码 | 修改 root、普通用户或 sudo 管理员密码，隐藏输入、至少 8 位并要求二次确认 |
| 增加管理员 | 将现有普通用户加入系统原生 `sudo` / `wheel` 组，并创建经过校验的独立 sudoers 规则 |
| 撤销管理员权限 | 将用户移出 `sudo` / `wheel` 组并删除本脚本创建的 sudoers 规则，保留账号和工作空间 |
| 删除用户 | 进入删除子菜单，可选择只删除账号并保留主目录，或将账号、主目录及邮件目录一起删除 |

- 用户名采用保守 Linux 规则：小写字母或下划线开头，最长 32 位，可包含数字、`_`、`-`。
- 密码至少 8 位、输入不回显并要求二次确认；不在命令行参数中传递。
- 修改密码前会展示目标账号的 UID、主目录和登录 Shell，并拒绝修改 `daemon`、`nobody` 等系统服务账号。
- 管理员规则保存到 `/etc/sudoers.d/vps-tools-<用户名>`，权限为 `440`，写入前必须通过 `visudo` 校验。
- 增加管理员采用事务式授权；用户组或 sudoers 校验失败时会回滚本次权限变更。
- 撤销管理员时禁止操作 root、系统服务账号和当前 sudo/doas 提权账号，并要求再次输入完整用户名确认。
- 如果用户还通过其他手写 sudoers 规则拥有权限，脚本只撤销可安全识别的常规授权并提示人工核对，不会擅自改写 `/etc/sudoers`。
- sudo 管理员检测会解析 `sudo -l -U <用户名>` 的实际授权内容，而不是只依赖命令退出码；撤权后若仍有其他授权，会显示完整权限报告并暂停等待确认。
- 密码设置或管理员授权失败时，会删除本次未完成的新用户，避免留下半配置账号。
- 管理员仍需输入自己的密码使用 sudo，不会配置免密 `NOPASSWD`。
- 删除用户必须再次输入完整用户名确认；脚本拒绝删除 root、系统账号、当前 sudo/doas 提权账号及仍有会话或进程的账号。
- 选择删除工作空间前会校验主目录路径，并拒绝删除系统关键目录或被其他账号共用的主目录；保留工作空间时，文件仍属于原 UID，需要管理员后续重新分配所有权。

---

### 3. Fail2ban 管理

自动封禁 SSH 暴力破解 IP。安装时自动检测 backend，支持 `python3-systemd` / `rsyslog` / `auto` 多种方式。

安装和修改 SSH 端口时会读取 `sshd` 的实际监听端口，并同步写入 `[sshd] port`，避免自定义端口后只封禁默认的 TCP 22。

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

### 4. BBR TCP 调优

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
- 首次调优保存运行参数基线，每次应用保存运行快照；失败时自动回滚
- 切换预设时检测上一场景遗留的转发/conntrack 参数，并恢复到首次调优前基线（`ip_forward` 单独警告）
- 中转/落地场景开启 IPv6 forwarding 时，为公网出口设置 `accept_ra=2`，保留 SLAAC 路由通告
- 逐行 `sysctl -w` 应用；非核心参数不支持时注释跳过，BBR 核心参数失败则拒绝持久化

**其他功能：**
- tc 限速（200M / 500M / 780M / 1G / 2G / 自定义）：`htb` 聚合整形 + `fq` 叶子保留 BBR pacing；兼容不可直接删除的默认 `mq`；默认拒绝外部 QoS，输入精确确认词后可接管或删除 `tbf` / CAKE / HTB 等 root qdisc，操作前诊断快照保存到 `/var/lib/vps-tools/tc-backups/`
- initcwnd（10 / 50 / 100 / 自定义），支持 IPv4/IPv6、无网关默认路由和 systemd/OpenRC/SysV 持久化
- 备份 / 还原 sysctl（按时间戳）

**代理专项参数：**
- 通用核心含 UDP 缓冲（`udp_rmem_min/wmem_min`），优化 QUIC / Hysteria2 / TUIC
- 场景预设（中转/落地）额外含扩大出站端口范围、`tcp_max_tw_buckets`、`fs.file-max`，防高并发端口/fd 耗尽
- 应用场景预设后自动检测代理 service 的 `LimitNOFILE`，偏低时询问写入 drop-in

**写入位置：** `/etc/sysctl.d/99-vps-bbr.conf`（不污染主配置）

---

### 5. 防火墙管理

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

### 6. DNS 优化

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

### 7. DDNS（Cloudflare / 华为云 DNS）

将动态公网 IP 自动同步到 DNS 服务商。当前支持 Cloudflare 和华为云 DNS。

**安装前准备：**
1. 域名托管到 Cloudflare 或华为云 DNS
2. 准备 API 凭据：Cloudflare 使用 API Token；华为云使用 AK/SK，账号需有 DNS 写权限
3. 准备 IPv4 / IPv6 使用的子域名

**支持配置：**
- IPv4 A 与 IPv6 AAAA 可分别启用、分别设置域名，也可以明确选择同域名双栈更新
- 双栈默认使用独立域名；例如 IPv4 子域名 `hktv4` 会自动建议 IPv6 子域名 `hktv6`
- Cloudflare 会严格按域名和类型匹配记录；检测到交叉残留记录时列出内容，确认后才会删除
- 支持仅 IPv4、仅 IPv6、IPv4+IPv6 双栈
- Cloudflare 支持代理（橙云）开关
- 华为云使用 AK/SK 签名调用 DNS API
- 自定义 TTL（Cloudflare 默认 60 秒，华为云默认 300 秒）
- 自定义检测间隔（1-59 分钟，默认 5 分钟，常用 1/2/5）
- 分享链接地址替换：保留协议、凭据、端口、参数和备注，按当前配置生成 IPv4 / IPv6 DDNS 链接
- 支持 SIP002/旧式 Shadowsocks、VMess，以及 VLESS、Trojan、Hysteria2、TUIC 等标准 URI

**运行机制：**
- crontab 按配置间隔执行，默认每 5 分钟
- IP 未变化时仅记录日志，不请求 API
- IP 多源备用：`ipify.org → ifconfig.me → ip.sb`
- IPv6 外部探测失败时，会回退读取本机 `scope global` IPv6 地址
- **IPv4 格式严格校验**：纯 IPv6 机器自动识别不会误发
- **IPv6 独立运行**：仅启用 AAAA 时不会因为无 IPv4 而退出
- **二次校验**：检测到 IP 变化时再查询一次，防止误推
- **事务式重配置**：新凭据或脚本测试失败时自动恢复原服务商、凭据和执行脚本，已有 cron 不会接管失败配置
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
| 修改配置 | 更换服务商 / 域名 / 凭据 / 模式 |
| 暂停 / 恢复 | 临时停用不删除配置 |
| 卸载 | 完整清理 |
| Telegram 通知 | 配置 Bot + Chat ID，发测试消息 |
| 替换分享链接地址 | 将已有节点中的 IP/主机替换为当前 IPv4、IPv6 或同域名双栈 DDNS 地址 |

**状态显示：**
- `运行中` — crontab 正常
- `已停止（cron任务未设置）` — 有 ddns.sh 但 crontab 未写入
- `已停止（cron未安装）` — 系统无 cron，自动安装入口

---

### 8. 系统换源

| 系统 | 支持的源 |
|------|---------|
| Ubuntu | 阿里 / 腾讯 / 清华 / 中科大 / 官方 |
| Debian | 阿里 / 腾讯 / 清华 / 中科大 / 官方 |
| CentOS / Rocky | 阿里 / 清华 / 默认 |

换源前自动备份，换源后自动 `apt update`。

---

### 9. IPv4/IPv6 配置

| 功能 | 说明 |
|------|------|
| 查看详细状态 | IP 地址 / 优先级 / 默认路由 |
| 设置 IPv4 优先 | 写入 `/etc/gai.conf` 立即生效 |
| 设置 IPv6 优先 | 移除 IPv4 优先规则，恢复系统默认 IPv6 优先 |
| 关闭 IPv6 | sysctl 持久化 |
| 开启 IPv6 | 恢复 sysctl + 等待 SLAAC |

---

### 10. Caddy 管理

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
- nftables 主配置：`/etc/nftables.conf`（保留用户规则，只加入 VPS Tools include）
- VPS Tools 托管规则：`/etc/nftables.d/vps-tools-nftpf.nft`（仅包含 `nftpf_*` 表，事务应用）
- 自动安装 nftables（apt / apk / yum / dnf）
- 自动开启 IP 转发
- 服务自启：systemd / OpenRC 双支持

---

### t. 时间同步

| 功能 | 说明 |
|------|------|
| 强制同步时间 | timesyncd → chrony → ntpdate → 多来源 HTTPS 兜底 |
| 设置北京时区 | Asia/Shanghai UTC+8 |
| 一键同步+北京时区 | 两步合一 |
| 其他时区 | 含常用时区参考 |
| 开启 NTP 自动同步 | timesyncd / chrony 自动选择 |
| HTTPS 时间同步 | 使用 TCP/443，适合 UDP/123 被封锁；支持立即同步及每 1/3/6/12/24 小时自动同步 |

HTTPS 同步保持证书验证开启，不使用 `curl -k`；依次探测 Cloudflare、阿里云、Microsoft、GitHub、Google，最多采纳 3 个有效来源，并拒绝相差超过 10 秒的结果。自动同步优先使用 systemd timer，无 systemd 时回退 root crontab，默认推荐每 6 小时；如果系统时间偏差大到 TLS 证书无法验证，需要先通过 VPS 控制台粗略校时。

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
| STUN / NAT 检测 | 多 STUN 端点与 UDP 443 / 3478 / 19302 探测，输出公网 IPv4 映射、Mapping / Filtering Behavior、传统 NAT 类型及动态结果解释；支持自定义主机与多端口 |
| 配置备份恢复 | 统一备份 SSH、防火墙、DNS、sysctl、Caddy、DDNS 和 NFT 配置；对包内配置根精确替换，不删除包中未包含的组件 |
| 操作记录 | 将关键操作、来源 IP 和结果写入 `/var/log/vps-tools-audit.log` |
| 系统资源健康 | CPU、负载、内存、磁盘、inode、连接、进程及失败服务 |
| 系统更新管理 | 检查更新、安全更新、完整更新、自动安全更新和缓存清理 |
| 修改系统 Hostname | 修改系统 hostname，并同步 `/etc/hostname` 与 `/etc/hosts`；用于改变 `root@主机名` 里的系统名 |
| 配置体检中心 | 汇总检查本地脚本、SSH、Fail2ban、监控 Bot、流量监控、日报、备份与历史版本 |
| 生成诊断包 | 导出脱敏诊断包，包含系统概览、服务状态、路由、资源、最近审计记录和关键配置快照 |

SSH、防火墙、DNS、IP 优先级及 IPv6 修改会启动 180 秒防断联保护。独立回滚快照不参与普通备份轮转；用户未确认新连接正常时，脚本会在互斥锁保护下恢复修改前的文件、缺失状态、`sysctl`/iptables 运行值和服务状态，失败时保留快照供人工处理。

高风险配置修改会先显示变更计划或逐行差异；配置备份默认保留最近 20 份，可通过环境变量 `VPS_BACKUP_KEEP` 调整。

SSH 登录策略使用 `sshd -T` 的有效配置组合判断，同时检查 `PasswordAuthentication`、`KbdInteractiveAuthentication`、`PermitRootLogin` 和 `AuthenticationMethods`，并显示 `UsePAM` 状态。`PermitRootLogin without-password` 会按 `prohibit-password` 的兼容别名正确识别，不再误报为允许 root 密码登录。

DNS 设置会自动识别 `systemd-resolved`、NetworkManager、resolvconf 或静态 `/etc/resolv.conf`，使用对应后端持久化配置。

### g. 监控告警中心

| 功能 | 说明 |
|------|------|
| 快速启用 | 按通知、主机名、日报、流量、续费和后台监控顺序完成首次配置 |
| 通知设置 | 单独配置 Telegram Bot Token / Chat ID、主机显示名和测试推送，告警、日报和续费提醒共用 |
| 后台监控 | 集中显示监控 cron、日报 cron 和下次日报时间，已配置但未启用时会明确提示 |
| 资源告警 | 磁盘、内存、负载、SSH、Fail2ban、Docker、Caddy 状态检查 |
| 流量监控 | 今日流量、周期流量、重置日、下行/上行校准和日阈值告警 |
| 每日日报 | 每天固定时间推送主机、今日流量、周期流量、24h/7d 趋势、周期起点和续费信息；启用日报时会自动安装对应分钟的独立 cron |
| 续费提醒 | 支持固定日期、按周期循环、每月固定日和提前提醒天数；可手动确认已续费，也可选择到期次日机器仍存活时自动顺延周期（默认关闭） |

到期存活自动顺延仅适用于“按周期循环”和“每月固定日”。例如续费日为每月 10 日，后台监控在 11 日仍正常运行时，会推定本期已续费并把日期推进到下月 10 日，同时写入历史和审计记录。服务商可能提供停机宽限期，因此该选项默认关闭，启用前会显示误判风险。
| 高级策略 | 可设置冷却时间、静默时段和恢复通知 |
| 最近告警记录 | 本地保留最近 80 条告警、静默和恢复记录，方便回看触发原因 |

告警冷却用于避免同一问题重复刷屏；静默时段会记录但不推送普通告警，恢复通知可在问题消失后主动推送。

---

### a. 软件与系统重装

**常用软件安装：**

| 分类 | 主要软件 |
|------|----------|
| 基础工具 | curl、wget、git、jq、压缩工具、编辑器、tmux、screen |
| 网络诊断 | iproute、DNS 工具、mtr、traceroute、tcpdump、socat、nmap |
| 系统监控 | htop、iftop、iotop、sysstat、lsof、ncdu |
| 开发环境 | 编译工具、Python、pip |

支持 apt、dnf、yum、apk、opkg 和 pacman，可同时选择多个分类；软件包按发行版映射并逐个安装，单个软件缺失不会中断整组。

**一键 DD / 系统重装：**

- 支持 Debian 12/13、Ubuntu 22.04/24.04、Alpine 3.20/3.22、Rocky Linux 9
- 支持自定义 RAW/VHD 镜像直链
- 使用 [`bin456789/reinstall`](https://github.com/bin456789/reinstall) 官方工具，下载后先执行 Bash 语法检查并显示计算出的 SHA256，便于审计
- 自动继承当前 SSH 端口；存在公钥时优先将首个公钥写入新系统
- 拒绝 OpenVZ、LXC、Docker 等容器环境
- 执行前显示根分区、系统磁盘和虚拟化类型，并要求输入 `ERASE-ALL-DATA`

> 系统重装会清空整块系统盘。执行前必须确认商家控制台/VNC可用，并在异地保存所有必要数据。第三方重装工具会在执行时从其官方仓库及系统镜像源继续下载资源。

---

### m. 脚本管理

| 功能 | 说明 |
|------|------|
| 安装 + 设置快捷键 | `/usr/local/bin/vps-tools` + `v` / `V` 软链接 |
| 从 GitHub 更新 | Manifest / SHA256 + Bash 语法校验、保存旧版本、覆盖并自动重启 |
| 离线安装 | 支持官方嵌套 Release 包和脚本内生成的扁平包，强制成员路径、SHA256、Bash 语法与版本标记校验 |
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
| root 权限检查 | 非 root 本地运行时可选择 sudo/doas 重新启动；网络运行和无提权权限时显示可复制的安全命令 |
| 用户管理安全 | 创建、改密和管理员授权均校验目标；授权失败自动回滚，撤权保护当前提权账号，删除保护活动账号和危险/共享主目录 |
| DDNS 脚本权限 | `chmod 700`，仅 root 可执行；API 凭据文件 `chmod 600` |
| 防火墙卸载警告 | 清空规则会暴露主机，2 秒延迟 + 警告 |
| pf_flush 警告 | 清空所有 NAT 规则会影响其他应用 |
| HTTPS 时间同步 | 强制校验证书并使用多来源时间共识，来源不足或差异过大时拒绝改时 |
| 内核支持检测 | BBR 应用前检测内核版本和模块 |
| 容器权限检测 | 自动识别无特权容器，sysctl 操作受限时友好提示 |
| 防断联保护 | 高风险网络修改 180 秒未确认自动回滚；同一时间只允许一个任务，状态跨脚本进程保存 |
| 更新完整性 | 下载脚本必须匹配仓库中的 SHA256 校验文件；临时文件使用 `mktemp`，不信任共享 `/tmp` 缓存 |
| DDNS 配置事务 | 重配置失败自动恢复旧凭据、服务商配置和执行脚本 |

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
| `/var/lib/vps-tools/rollback.active` | 当前防断联回滚任务状态（600） |
| `/var/lib/vps-tools/update_available` | 后台版本检测结果 |
| `/var/log/vps-tools-audit.log` | 脚本操作审计日志（600） |
| `/etc/sudoers.d/vps-tools-<用户名>` | 本脚本创建的管理员 sudo 规则（440，经过 visudo 校验） |
| `SSH-Hardening.sh.sha256` | 自更新完整性校验值 |
| `/etc/sysctl.d/99-vps-bbr.conf` | BBR TCP 配置 |
| `/var/lib/vps-tools/bbr-sysctl-baseline.conf` | BBR 首次调优前运行参数基线（600） |
| `/etc/nftables.conf` | nftables 主配置（保留用户规则） |
| `/etc/nftables.d/vps-tools-nftpf.nft` | VPS Tools 托管的 NFT 转发规则 |
| `/etc/nft-port-forward/rules.db` | NFT 转发规则数据库 |
| `/etc/nft-port-forward/access.conf` | NFT 访问控制配置 |
| `/etc/systemd/system/nftpf-ddns.timer` | NFT DDNS 自动刷新 timer |
| `/root/.cf_token` | Cloudflare API Token（600） |
| `/root/.hw_dns_aksk` | 华为云 DNS AK/SK（600） |
| `/root/.cf_zone` | DDNS 服务商、域名、模式、Endpoint、TTL、检测间隔配置 |
| `/root/.cf_tg` | Telegram Bot 配置（600） |
| `/root/ddns.sh` | DDNS 执行脚本（700） |
| `/var/log/ddns.log` | DDNS 日志（自动轮转 500 行） |
| `/etc/fail2ban/jail.local` | Fail2ban 用户配置 |
| `/etc/caddy/Caddyfile` | Caddy 站点配置 |

---

## 开源地址

```
https://github.com/TonyJsonson-8748/SSH-Hardening
```

```bash
# 一行安装
bash <(curl -fsSL https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/refs/heads/main/SSH-Hardening.sh)
```

### 开发与构建

仓库源码位于 `src/lib/` 和 `src/modules/`。用户安装的 `SSH-Hardening.sh` 是由模块生成的完整单文件，运行时不下载任何模块：

```bash
./build.sh          # 生成单文件并刷新 SHA256
./build.sh --check  # 检查发行文件是否与模块源码一致
tests/smoke.sh
tests/fault-injection.sh
tests/offline-package.sh
```

GitHub Actions 还会在 Debian、Ubuntu、Alpine、Rocky Linux 容器中加载生成脚本并执行冒烟测试。

仓库通过 `.gitattributes` 强制 Bash、SHA256、JSON、YAML 和 Markdown 使用 LF 行尾，并统一构建器在 Windows/Linux 下的 SHA256 文件格式；Windows 上即使启用 `core.autocrlf=true`，发布脚本也不会被转换为 CRLF。已有旧工作区可在提交本地改动后重新检出，以应用新的行尾规则。

### BBR 独立仓同步

`src/modules/bbr.sh` 同时发布到 [chnnic/BBR-tune](https://github.com/chnnic/BBR-tune)。修改 BBR 行为或其依赖的 core helper 后，必须在同一批工作中同步并推送独立仓：

```bash
cd ../BBR-tune
scripts/sync-from-upstream.sh ../SSH-Hardening
scripts/sync-from-upstream.sh --check ../SSH-Hardening
tests/smoke.sh
```

详细规则由主仓 [AGENTS.md](AGENTS.md) 和独立仓 `SYNC_BBR.md` 共同维护。

---

## 版本沿革（近期）

| 版本 | 主要变更 |
|------|---------|
| **V3.50.2** | 修复离线包校验函数 `self_offline_archive_validate` 中 `RAW_TAR` 在同一条 `local` 语句内引用刚声明的 `TYPE_LIST` 导致取值错误的作用域 bug；移除已被拆分字段取代的死变量 `FIREWALL_IPTABLES_RULES`/`FIREWALL_ALLOW_FIREWALLD_ADDED`；清理归档路径校验中被更宽泛规则覆盖的冗余模式；消除全部 CI shellcheck 警告 |
| **V3.50.1** | 合并上游 BBR tc 限速修复：多队列网卡默认 `mq` 无法 `tc qdisc del` 导致限速失败，改用 `replace` 原子安装 HTB 并同步修复持久化辅助脚本；默认仍拒绝覆盖外部 QoS，展示现有 qdisc/class/filter 后输入 `FORCE <网卡>` 可强制接管、输入 `DELETE <网卡>` 可删除外部限速，操作前将文本与 JSON 诊断快照保存到 `/var/lib/vps-tools/tc-backups/` |
| **V3.50.0** | 全面强化 SSH、公钥、防火墙、用户管理及防断联事务：配置和密钥写入加入并发变更检测；防火墙覆盖双栈、区域绑定和部分回滚；回滚状态校验文件内容、存在性、进程身份与服务启用状态；离线包、监控/NFT 定时任务、Swap 与自更新进一步增加完整校验、原子替换和失败恢复 |
| **V3.20.3** | SSH 工具集生成密钥对后不再固定写入 root：默认目标仍为 root，也可指定其他可交互登录用户或完全跳过服务器写入；复用有效 `AuthorizedKeysFile`、文件类型、属主、权限、公钥格式与去重校验，并记录生成、写入和跳过操作日志 |
| **V3.20.2** | 合并上游离线安装包、GitHub Release 发布工作流与 HTTPS 自动校时：支持每 1/3/6/12/24 小时通过 systemd timer 或 root crontab 执行，记录最近结果并防止任务重叠；修复交互式首次同步后锁文件描述符未及时释放的问题；README 的安装、离线构建和仓库地址继续以长期维护 Fork 为准 |
| **V3.20.1** | SSH 工具集的查看、删除公钥改为指定用户并支持多个有效 `AuthorizedKeysFile`；删除按物理行精确执行，新增变更并发检查、删除前后登录路径与完整管理入口校验、原文件独立备份及 180 秒自动回滚；补充严格模式各项配置说明 |
| **V3.20.0** | SSH 工具集新增严格模式：仅在确认存在可管理的非 root 有效密钥入口后禁用 root、密码、键盘交互与 X11，并收紧认证次数及保活；“添加公钥”改为指定用户、支持空输入取消并用 `ssh-keygen` 验证；新增带剩余登录及管理入口校验的指定用户 SSH 登录撤权 |
| **V3.11.9** | 修复撤销管理员后，部分 sudo 环境仅凭 `sudo -l -U` 退出码可能继续把普通用户显示为管理员；改为解析实际授权结果，并在存在其他 sudoers 来源时展示权限报告 |
| **V3.11.8** | 修复系统安全体检将 `PermitRootLogin without-password` 误报为允许 root 密码登录；改为组合判断密码、键盘交互、root 策略、PAM 与 AuthenticationMethods，并显示实际有效值 |
| **V3.11.7** | 用户管理新增“增加管理员”和“撤销管理员权限”：支持现有用户事务式授权，撤权时移除 sudo/wheel 组及托管 sudoers，并检测其他残留授权来源 |
| **V3.11.6** | 用户管理新增密码修改：支持 root、普通用户和 sudo 管理员，复用隐藏输入、长度及二次确认校验，并拒绝系统服务账号 |
| **V3.11.5** | 修复用户列表页面调用不存在的暂停函数，导致列表一闪而过并立即返回用户管理菜单 |
| **V3.11.4** | 用户管理新增安全删除子菜单：可保留工作空间或连同主目录删除；增加完整用户名确认，并保护 root、系统账号、当前提权账号、活动账号及危险/共享主目录 |
| **V3.11.3** | 新增用户管理模块：创建普通用户或 sudo 管理员、隐藏密码二次确认、原生管理组与独立 sudoers 校验、失败自动删除半配置账号；改进非 root 启动提示，本地脚本支持 sudo/doas 重新运行 |
| **V3.11.2** | 将快速开始、命令行调用、安装清单和脚本自更新源切换到长期维护 Fork `TonyJsonson-8748/SSH-Hardening`，同时保留上游原仓库说明 |
| **V3.11.1** | Fail2ban 安装及 SSH 改端口时同步实际监听端口；自更新改用安全临时文件并移除共享 `/tmp` 脚本缓存；防断联回滚任务增加持久单实例保护；Cloudflare/华为云 DDNS 重配置失败自动恢复旧配置；新增 `.gitattributes` 固定 Linux 发布文件为 LF |
| **V3.11.0** | 时间菜单新增 HTTPS 时间同步，使用 TCP/443 适配 UDP/123 被封锁的 VPS；从 Cloudflare、阿里云、Microsoft、GitHub、Google 获取经 TLS 验证的 `Date` 响应，至少两个来源在 10 秒内达成共识才设置系统时间，并作为普通强制同步的最终兜底 |
| **V3.10.9** | 修复未配置公钥时首页和 SSH 工具集显示 `0` 后又换行显示第二个 `0`：保留 `grep -c` 的零计数输出，空文件或文件不存在时统一返回单个 `0` |
| **V3.10.8** | 修复 Caddy 站点列表在 Tab 缩进或嵌套 `reverse_proxy` / `header_up` / `transport` 块下误把内部指令当作站点、真实后端显示不完整及站点计数错误；查看、删除与计数统一按顶层配置块解析，并正确保留多域名站点标题 |
| **V3.10.7** | 续费提醒新增可选的“到期次日存活自动顺延”：每月固定日或循环续费到期后，后台监控仍运行即推定已续费，按原周期推进日期并记录历史、审计，已配置 Telegram 时发送通知；默认关闭且明确提示服务商宽限期可能造成误判 |
| **V3.10.6** | DDNS 新增分享链接地址替换工具：粘贴已有 SS、VMess、VLESS、Trojan、Hysteria2、TUIC 等节点 URI，保留凭据、端口、参数和备注，自动生成当前 IPv4 / IPv6 或同域名双栈 DDNS 链接 |
| **V3.10.5** | 修复 DDNS 双栈配置容易把 AAAA 默认放到 IPv4 子域名的问题：新增共用/独立域名明确选择，默认独立并将 `hktv4` 建议为 `hktv6`；Cloudflare 严格复核记录域名与类型，拒绝同类型重复记录，并可在用户确认后清理 IPv4 域名上的旧 AAAA 或 IPv6 域名上的旧 A |
| **V3.10.4** | 首页 `IMPART OPS` 品牌标题改为 ANSI Shadow 块状字幅；76 列终端同行完整展示，47-75 列终端上下分行，更窄终端自动回退为居中纯文字，避免手机终端折行错位 |
| **V3.10.3** | STUN 检测结果下方新增动态解释区，分别说明 UDP 连通性、NAT 类型、映射行为、过滤行为、判定置信度和使用建议；覆盖公网直连、UDP 过滤、各类锥型、对称型、细分未知及无响应结果 |
| **V3.10.2** | STUN 快速检测移除频繁超时的 Sipgate 3478/3479，改用 Nextcloud 443/3478、Cloudflare 3478、Google 19302 和 MiWiFi 3478；保留同地址跨端口映射判定，并同步更新自定义检测默认值 |
| **V3.10.1** | Cloudflare DDNS 配置时 API Token 改为明文回显，便于确认是否输入及检查粘贴内容；确认页仍只显示前 8 位，凭据文件继续使用 600 权限 |
| **V3.10.0** | 新增 STUN 检测、多端口 UDP 探测和 NAT 类型判定；同一 UDP socket 探测多个端点，支持 RFC 5389 / RFC 5780 地址与过滤行为分析、自定义 STUN 主机和最多 12 个端口，并在证据不足时降低置信度而不强行判型 |
| **V3.9.48** | 修复升级到 V3.9.45 后，旧版生成的 `htb 1:` + `fq 100:` 限速因缺少状态文件被误判为外部 QoS；通过完整 tc 拓扑与持久化文件标记安全迁移，仍拒绝覆盖真正的第三方规则 |
| **V3.9.47** | 修复通过 `bash <(curl ...)` 运行时安装函数复制 `/dev/fd` 流导致本地脚本被截断；安装前后增加语法与版本标记校验，失效快捷键自动修复，测试改用隔离目录且不再污染宿主机 `/usr/local/bin/v` |
| **V3.9.46** | 修复 UFW 放行失败仍启用导致断联、配置导入可覆盖任意路径、NFT 覆盖用户规则及失败无回滚、Swap 关闭失败仍删除、DDNS 占位记录与 cron 假成功、Caddy/Fail2ban/DNS/IPv6/NTP 错误传播；换源支持 deb822 并为 RPM 仓库增加验证回滚 |
| **V3.9.45** | 修复 BBR 场景切换写入危险默认值、智能向导绕过预检和应用失败误报；增加运行参数回滚、IPv6 RA 保护、tc 规则所有权、跨 init 持久化、无网关/IPv6 initcwnd 路由解析，并修正 BDP 与 4GB 推荐逻辑 |
| **V3.9.44** | 修复监控告警通知失败仍标记成功、续费日期未经确认自动推进、冷却签名随指标变化失效、cron 并发重复推送、多网卡流量重复统计和阈值输入缺少校验 |
| **V3.9.43** | 修复 DDNS 二次确认分支无法触发、失败状态覆盖最近成功 IP、短间隔并发执行、华为云查询失败误创建及 cron 误匹配；敏感凭据输入不再回显 |
| **V3.9.42** | DDNS 检测到本机公网 IP 变化时，即使 DNS 记录已同步，也会记录 `IP变化` 并推送 Telegram |
| **V3.9.41** | 修复 DDNS 首页变更记录可能显示旧 IP 状态的问题，按最新状态过滤并比较日志/状态时间 |
| **V3.9.40** | 自更新优先锁定 GitHub main commit 下载脚本、manifest 和 SHA256，避免 raw/CDN 缓存不一致导致校验失败 |
| **V3.9.39** | DDNS 支持自定义检测间隔分钟数，安装、修改和恢复自动更新时写入对应 cron，可设 1 / 2 / 5 分钟等 |
| **V3.9.38** | DDNS IPv6 外部探测失败时回退读取本机全局 IPv6，避免有公网 IPv6 但 `curl -6` 不通时报“无法获取公网 IPv6” |
| **V3.9.37** | DDNS 新增华为云 DNS 服务商，支持 AK/SK 签名调用华为云 DNS API 更新 A / AAAA 记录，并保留 Cloudflare 旧配置兼容 |
| **V3.9.36** | 流量监控记录上次网卡计数，VPS 重启或网卡计数重置后把已用流量滚入持久 offset，避免今日/周期统计回到 0 |
| **V3.9.35** | 修复监控配置被 `source` 执行的风险；SSH 加固写入置顶托管块避免被 `Include` 覆盖；NFT 转发不再 `flush ruleset` 清空宿主机规则；修复 Telegram HTML 转义 |
| **V3.9.34** | 修复 VPS 重启或网卡计数重置后，流量监控当前周期被旧基线钳成 0、长期不增长的问题 |
| **V3.9.33** | DDNS 首页按 IPv4 A / IPv6 AAAA 分别展示最新状态和最后变更，避免双栈时只看到最后执行的 AAAA |
| **V3.9.32** | 修复 DDNS 菜单最后变更时间变量误用 `LC_TIME` 导致的 locale warning |
| **V3.9.31** | DDNS 支持 IPv4 A 与 IPv6 AAAA 分别设置，可同域名或不同子域名同时更新；仅启用 IPv6 时不再依赖 IPv4 |
| **V3.9.30** | 修正 SSH 改端口流程：先确认新端口可登录，再决定是否关闭旧端口，避免关闭旧连接后才发现新端口不可用 |
| **V3.9.29** | 修复每日日报和续费提醒同日重复推送；Telegram 推送中的主机显示名增加 HTML 转义，避免 `<`、`&` 等字符破坏消息格式 |
| **V3.9.28** | 首页采用清爽运维风，缩小 `IMPART OPS` 字幅，并增加 `VPS 开荒脚本 · 银趴火山帮` 副标题 |
| **V3.9.27** | 统一所有交互界面标题为 `VPS TOOLS · 版本号` 与当前模块名，主菜单和特殊模块不再使用不同标题风格 |
| **V3.9.26** | 流量监控启用时新增“是否清除旧记录”确认，可保留旧统计或从当前流量重新统计 |
| **V3.9.25** | 安全与诊断工具箱新增“修改系统 Hostname”，支持校验后写入 `/etc/hostname` 并同步 `/etc/hosts`，用于修改 SSH 提示符中的系统主机名 |
| **V3.9.24** | 续费提醒新增“我已续费”，确认后跳过当前周期并从下一周期继续提醒 |
| **V3.9.23** | 日报、流量、续费和资源告警子页统一增加“立即发送一次”，可手动推送对应模块的实时快照 |
| **V3.9.22** | 重排监控告警中心流程，新增快速启用、通知、日报、流量、续费、资源、高级策略和后台监控独立页面，保留旧配置兼容 |
| **V3.9.21** | 每日日报启用 / 改时间时自动安装独立 cron，按 `23:59` 这类精确分钟推送，避免被 10 分钟监控轮询错过 |
| **V3.9.20** | 监控日报和测试快照新增 24h / 7d 趋势摘要，资源 / 流量 / 续费告警支持提醒、警告和严重分级 |
| **V3.9.19** | 监控告警中心增强，支持冷却时间、静默时段、恢复通知、检查项开关和最近告警记录 |
| **V3.9.18** | 新增配置体检与诊断包入口，并引入 manifest 支撑更新校验 |
| **V3.9.17** | 服务管理统一使用 `systemd_available` 检测，减少 cron / 容器环境下的 systemd 误判 |
| **V3.9.16** | 流量监控阈值设置与启用逻辑拆分，修改阈值不再重置今日与周期累计 |
| **V3.9.15** | 监控告警 SSH 状态同时兼容 `ssh` / `sshd`，并移除 cron 环境下易误判的 `pidof systemd` 依赖 |
| **V3.9.14** | 整理 README 版本沿革为单一倒序表，去除 V3.9.x 重复追加导致的排序混乱 |
| **V3.9.13** | 新增全模块 CLI 菜单入口和 `--help` 命令，并在 README 汇总命令行合集 |
| **V3.9.12** | 新增 DDNS 独立 CLI 入口，支持从 GitHub 直接拉起 DDNS 菜单、安装、运行和日志查看 |
| **V3.9.11** | 续费提醒页面按模式显示字段，避免每月固定日与周期天数同时出现 |
| **V3.9.10** | 流量重置日遇到短月时顺延到下月 `1` 日，避免 `31` 被提前到月底 |
| **V3.9.9** | 流量重置日限制为 `1-31`，并明确 `31` 遇到短月时按当月月底计算 |
| **V3.9.8** | 周期流量校准支持大于网卡累计值的人工修正，避免显示被当前计数器上限截断 |
| **V3.9.7** | 周期流量校准支持分别设置下行/上行，并避免旧合计基线误补分项导致下行归零 |
| **V3.9.6** | 修复旧流量基线科学计数法导致的 Bash 算术错误；流量监控子页统一 `↓1.45G ↑1.81G ↓↑3.26G` 显示 |
| **V3.9.5** | 更新器增加多源重试和 hash 诊断；终端与 Telegram 的流量显示统一为 `↓1.45G ↑1.81G ↓↑3.26G` 简洁格式 |
| **V3.9.4** | 监控流量统计拆分为下行、上行和合计，并同步显示到监控首页、每日日报、测试告警和流量超限告警 |
| **V3.9.3** | 日报时间支持 `23:59` / `2359`，续费日期支持 `2026-05-15` / `20260515`；测试告警改为发送当前系统状态快照 |
| **V3.9.2** | 监控首页保留唯一 Bot 配置入口；每日日报改为真正分段文本，避免 Telegram 显示成一行 |
| **V3.9.1** | 强制更新加入重试与缓存失效参数，降低 GitHub raw 拉取和 SHA256 校验的误报 |
| **V3.9.0** | 监控首页新增共用 Bot 配置入口；流量统计输出改为纯整数，避免部分环境出现科学计数法导致的算术错误 |
| **V3.8.9** | 监控推送支持自定义主机显示名，便于多台机器区分，默认仍使用 hostname |
| **V3.8.8** | 监控告警中心独立到首页，新增每日日报、流量重置日和当前周期流量统计，可按月固定日重置并手动校准当前周期消耗 |
| **V3.8.7** | 新增离线安装包与监控告警中心，支持本地打包安装脚本、生成离线安装包，并通过定时检查对磁盘、负载和关键服务状态进行告警 |
| **V3.8.6** | 新增配置导出/导入与统一回滚中心入口，集中管理配置备份恢复、脚本版本回滚和迁移操作 |
| **V3.8.5** | 新增从 URL 拉取 Compose 文件、自动校验并部署的入口，支持先预览再落盘执行 `docker compose up -d --pull always` |
| **V3.8.4** | 新增 Docker Engine 与 Compose 插件一键安装；新增容器查看、详情、启停、重启、日志、Shell 和删除管理；Compose 容器可拉取新镜像并按原配置重建，普通容器采用无损镜像更新检查，避免丢失启动参数 |
| **V3.8.3** | 新增常用软件多选安装，适配 apt/dnf/yum/apk/opkg/pacman；新增使用官方重装工具的一键 DD/Linux 重装向导，包含容器拒绝、目标磁盘展示、脚本语法检查与 SHA256 展示、SSH 参数继承及固定确认词保护 |
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
