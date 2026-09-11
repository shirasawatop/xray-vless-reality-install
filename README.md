# xray-vless-reality-install

> Debian 12/13 上一键部署 Xray 服务端，支持 **REALITY（+ sni-filter）** 与 **VLESS Encryption** 两种形态，带成体系的文件权限模型与一套管理命令。
> *One-command installer for Xray on Debian: **VLESS over REALITY (with sni-filter)** or **VLESS-Encryption**, with a hardened file-permission model and a full set of management commands.*

| 项 | 值 |
|---|---|
| 当前版本 | **v1.0.0（2026-09-11）** |
| 目标系统 | Debian 12 / 13（systemd） |
| 脚本 | [`xray-vless-reality-install.sh`](./xray-vless-reality-install.sh) |
| 安装目录 | `/var/xray` |
| 运行用户 | `xrayuser`（`nologin`，仅用于运行服务） |
| 许可 | [MIT](./LICENSE) © 2026 shirasawatop |

---

## 特性

- **两种形态二选一**（同一 inbound 不可共存）：

  | 形态 | 443 监听者 | xray inbound |
  |---|---|---|
  | **REALITY**（+ sni-filter） | `sni-filter`（用户态） | unix socket `socket/xray.friend,0600`，`security=reality` |
  | **VLESS Encryption** | `xray` 本体 | `port:<你的端口>`，`security=none` + `decryption=mlkem768x25519plus…` |

- **交互式**：全程问答（若装了 `whiptail` 则以对话框菜单呈现），无需手改 JSON。
- **成体系的权限模型**（本脚本的重点，见下文）：二进制与入口脚本归 `root`、服务账户只读可执行；`config.json` 为 `640 root:xrayuser`；含密钥的管理脚本 `700`。
- **前置检查**：root 身份校验、依赖检查（`wget` / `openssl` / `unzip`）、**重复安装二次确认**。
- **systemd 集成**：`User=xrayuser` + `AmbientCapabilities=CAP_NET_BIND_SERVICE`（**不使用 `setcap`**）、`Restart=on-failure`。
- 可选：IPv4/IPv6 出口选择与优先顺序、DDNS 检测脚本、MTU 调整（经 unit 的 `ExecStartPre` 生效）、socks5 落地。

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | Debian 12 / 13，systemd 可用（其它发行版未验证） |
| 权限 | **root**（需写 `/etc/systemd/system`、创建系统用户、绑定 443） |
| 依赖 | `wget`、`openssl`、`unzip`（脚本会检查并给出安装命令） |
| 网络 | 可访问 `github.com`（下载 Xray 与 sni-filter）与 `cloudflare.com`（探测公网 IP） |
| 架构 | `x86_64` / `i686` / `aarch64` |

## 快速开始

```bash
# 1) 下载
wget -O /root/xray-vless-reality-install.sh \
  https://raw.githubusercontent.com/shirasawatop/xray-vless-reality-install/main/xray-vless-reality-install.sh

# 2) 赋予执行权限并运行（必须 root）
chmod +x /root/xray-vless-reality-install.sh
bash /root/xray-vless-reality-install.sh
```

> 建议先开一个 `tmux`/`screen` 会话再执行（安装过程包含下载与交互问答）。

## 交互流程

| 顺序 | 提问 | 默认值 | 说明 |
|---|---|---|---|
| 0 | 协议选择 | — | `1) REALITY`（伪装网站，抗主动探测）/ `2) VLESS Encryption`（自带加密，抗量子） |
| 1 | 自动检测公网 IP | — | 通过 `cloudflare.com/cdn-cgi/trace` 探测 IPv4/IPv6 |
| 2 | 是否优先使用 IPv6 出口 | `y` | 影响路由规则顺序（仅在有双栈出口时生效） |
| 3 | 出口地址 | 自动检测 | 可选「使用检测到的地址 / 手动输入 / 不使用」 |
| 4 | 是否开启 DDNS 自动更换 IP | `n` | 开启后生成 `/var/xray/ddns_check.sh` 与 `ddns.config`（**定时需自行挂 cron**） |
| 5 | 是否开启 MTU 调整 | `n` | 接口默认 `eth0`、值默认 `1390`，以 `ExecStartPre=ip link set …` 写入 unit |
| 6 | 监听 IP / 端口 | `0.0.0.0` / `443` | 443 需 `CAP_NET_BIND_SERVICE`（脚本已处理） |
| 6a | **REALITY 专属**：伪装域名 | `tesla.com` | 建议选**支持 TLS1.3 的境外站点**；`dest=域名:443`、`serverNames=[域名]` |
| 6b | **REALITY 专属**：指纹 `fp` | `chrome` | 可选 chrome / firefox / safari / ios / edge |
| 6c | **Encryption 专属**：密钥模式 | `mlkem768` | `mlkem768`（抗量子，推荐）/ `x25519`（传统） |
| 6d | **Encryption 专属**：外观 | `native` | `native` / `xorpub` / `random`（越靠后越隐蔽） |
| 6e | **Encryption 专属**：RTT | `0rtt` | `0rtt`（更快）/ `1rtt`（更安全） |
| 6f | **Encryption 专属**：Ticket 时长 | `600`（秒） | 仅 `0rtt` 模式生效 |
| 7 | 落地方式 | — | `直接落地` / `socks5 落地`（后者需填 IP、端口、用户、密码） |

> 小贴士：`apt-get install -y whiptail` 可获得对话框式交互，避免长选项敲错。

## 安装后会生成什么

**文件与权限**（`/var/xray`）：

| 文件 / 目录 | 权限 | 属主 | 说明 |
|---|---|---|---|
| `xray` | `755` | `root:root` | Xray 本体（**服务账户不可写**，只可执行） |
| `sni-filter` | `755` | `root:root` | 仅 REALITY 形态（443 的实际监听者） |
| `xrayinit` | `755` | `root:root` | 启动脚本（拉起 sni-filter 与 xray） |
| `config.json` | `640` | `root:xrayuser` | 服务配置；服务账户经 group 位读取 |
| `uuid.txt` | `600` | `root:root` | 当前客户端 UUID（供 `xray.chaguuid` 使用） |
| `encryption_key.txt` | `600` | `root:root` | 仅 Encryption 形态 |
| `chaguuid` | `700` | `root:root` | **内联客户端订阅参数**，故仅 root 可读 |
| `xray{start,stop,restart,help,status,log}`、`delxray` | `755` | `root:root` | 管理脚本 |
| `socket/`、`xray.pid`、`sni-filter.pid`、`statusfilter` | — | `xrayuser:xrayuser` | 运行期产物 |
| 目录 `/var/xray` | `755` | `xrayuser:xrayuser` | 服务需要在其中写 pid / socket |

**其它位置**：

| 路径 | 说明 |
|---|---|
| `/etc/systemd/system/xray_service.service` | systemd 单元（`User=xrayuser` + `AmbientCapabilities`） |
| `/usr/bin/xray.*`、`/usr/local/bin/xray.*` | 管理命令符号链接（`xray.chaguuid`、`xray.status` 等） |

> **权限模型的设计意图**：服务以低权账户 `xrayuser` 运行，但**二进制与入口脚本归 `root`**，避免"低权账户可写、root 可执行"这一经典提权组合；`config.json` 与含密钥的脚本只给到必要的读权限。请勿随意放宽上述权限。

## 管理命令

| 命令 | 作用 |
|---|---|
| `xray.status` | 查看服务状态、端口监听与两个进程 |
| `xray.start` / `xray.stop` / `xray.restart` | 启停 / 重启服务 |
| `xray.log` | 最近 50 行服务日志（支持 `-f` 等 `journalctl` 参数） |
| `xray.chaguuid` | **更换客户端 UUID**（改 `config.json` 并重启，随后打印新订阅链接） |
| `xray.help` | 命令一览 |
| `xray.delxray` | **卸载**（停止并禁用服务、删除 `/var/xray` 与 `xrayuser`；需输入 `yes` 确认） |

## 订阅链接

安装结束与执行 `xray.chaguuid` 时会打印（`<…>` 为占位）：

```text
# REALITY
vless://<uuid>@<ip>:<port>?encryption=none&flow=xtls-rprx-vision&security=reality&sni=<domain>&fp=chrome&pbk=<publicKey>&sid=<shortId>&type=tcp&headerType=none&host=<domain>#xray_REALITY

# VLESS Encryption
vless://<uuid>@<ip>:<port>?encryption=<encryption_str>&flow=xtls-rprx-vision&security=none&type=tcp#xray_Encryption
```

## 验证与排障

```bash
# 服务与端口
systemctl status xray_service --no-pager
ss -tlnp | grep ':443\b'          # REALITY: 属主是 sni-filter；Encryption: 属主是 xray
pgrep -a 'xray|sni-filter'
journalctl -u xray_service -n 50 --no-pager

# 权限复核（应与此一致）
stat -c '%n %a %U:%G' /var/xray/xray /var/xray/sni-filter /var/xray/config.json /var/xray/chaguuid
```

| 现象 | 排查方向 |
|---|---|
| 提示缺少 `unzip`/`wget`/`openssl` | 按提示 `apt-get install -y …` 后重跑 |
| 端口未监听 | `journalctl -u xray_service -n 50`；确认端口未被占用（`ss -tlnp \| grep :443`） |
| REALITY 形态看不到 `xray` 监听 443 | **正常**：443 由 `sni-filter` 监听，xray 走 unix socket |
| 客户端连不上 | 核对链接里的 `uuid`、`sni/host`、`pbk`、`sid`、`fp` 是否与安装输出一致；确认客户端时间准确 |
| 重跑安装脚本后客户端全失效 | 预期行为：重跑会**重新生成密钥与 UUID**（脚本已二次确认）；请用新链接更新客户端 |

## 安全说明

- **不做任何数据回传/遥测**。脚本只访问：`github.com`（Xray 与 sni-filter 发布页）、`cloudflare.com`（探测公网 IP）。
- **重跑会重新生成 REALITY 密钥与 UUID 并覆盖 `config.json`** ⇒ 现有客户端立即失效（脚本已内置二次确认）。
- `xray.chaguuid` 会更换 UUID，**所有客户端需同步更新**；`xray.delxray` 为破坏性操作（`rm -rf /var/xray`）并需 `yes` 确认。
- `chaguuid` 换 UUID 时的 `sed` 替换已做**输入白名单 + 长度 + 定点存在性 + 元字符转义**四重校验，避免恶意 `uuid.txt` 内容注入 `sed` 命令（历史上这类写法可导致 root 命令执行）。
- 本脚本**不配置防火墙 / BBR / fail2ban / SSH 加固**，请自行完成主机侧基线加固。
- 脚本会创建系统用户 `xrayuser`（`/sbin/nologin`）并写 `/etc/systemd/system/xray_service.service`。

## 卸载

```bash
xray.delxray            # 需输入 yes 确认；会停止服务、禁用开机自启、删除 /var/xray 与 xrayuser
```

## 外部依赖与下载源

| 组件 | 来源 | 用途 |
|---|---|---|
| Xray-core **v26.3.27** | `github.com/XTLS/Xray-core` releases | 服务端本体（三个架构分支） |
| realtime sni-filter **v0.2** | `github.com/shirasawatop/REALITY-sni-filter` releases（**与本项目同作者**） | **仅 REALITY 形态**：443 监听者 |
| `cloudflare.com/cdn-cgi/trace` | Cloudflare | 探测公网 IPv4 / IPv6 |

## 已知限制

1. 仅在 Debian 12/13（systemd）实测；其它发行版可能需要自行适配。
2. Xray 版本在脚本内**硬编码**（`v26.3.27`，3 处 URL），升级需手动改。
3. DDNS 只生成脚本并执行一次，**定时调度需自行挂 cron / systemd timer**。
4. 安装后只验证**服务端**（服务状态、端口、进程）；真实客户端连通性请自行测试。
5. 未启用 `set -u`（脚本内可选变量较多，逐条排查成本较高）。
6. `config.json` 的属主为 `xrayuser` 还是 `root:xrayuser` 取决于部署时的版本；本版本使用后者。

## 变更记录

**v1.0.0（2026-09-11）** —— 首次公开发布

- 二合一部署：REALITY（+ sni-filter）/ VLESS Encryption。
- 权限模型收紧：`uuid.txt`/`encryption_key.txt` → `600`（含 `chaguuid` 内部重写路径）；`config.json` → `640 root:xrayuser`；`chaguuid` → `700`；`xray`/`sni-filter`/`xrayinit` → `root` 所有（**修掉"低权账户可写、root 可执行"的提权路径**）。
- `chaguuid` 修复 `sed` 注入面（输入白名单 / 长度 / 定点存在性 / 元字符转义），并顺带修复 `uuid.txt` 与 `config.json` 不一致时仍打印订阅链接的问题。
- 新增前置检查：root 身份、依赖检查（含安装提示）、重复安装二次确认。
- `xrayhelp` 命令名笔误修正（`xray.chuuid` → `xray.chaguuid`）；`delxray` 增加二次确认。

## 许可

**MIT License** ｜ Copyright (c) 2026 [shirasawatop](https://github.com/shirasawatop) ｜ 全文见 [`LICENSE`](./LICENSE)

- 可自由使用、修改、分发，需保留版权与许可声明。
- REALITY 形态会下载 [`REALITY-sni-filter`](https://github.com/shirasawatop/REALITY-sni-filter)（与本项目同作者），该组件按其仓库自身的许可执行；Xray-core 版权归 [XTLS/Xray-core](https://github.com/XTLS/Xray-core) 所有。
