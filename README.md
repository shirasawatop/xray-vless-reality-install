# xray-vless-reality-install

> Debian 12/13 上一键部署 Xray 服务端，支持 **REALITY（+ sni-filter）** 与 **VLESS Encryption** 两种形态，带成体系的文件权限模型与一套管理命令。
> *One-command installer for Xray on Debian: **VLESS over REALITY (with sni-filter)** or **VLESS-Encryption**, with a hardened file-permission model and a full set of management commands.*

| 项 | 值 |
|---|---|
| 当前版本 | **v1.0.3（2026-09-12）** |
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
| 6a | **REALITY 专属**：伪装域名 | **`www.fastly.com`** | 需**支持 TLS1.3** 的境外站点，常用 **`tesla.com`**；`dest=域名:443`、`serverNames=[域名]`（选法见「例 1」下方） |
| 6b | **REALITY 专属**：指纹 `fp` | `chrome` | 可选 chrome / firefox / safari / ios / edge |
| 6c | **Encryption 专属**：密钥模式 | `mlkem768` | `mlkem768`（抗量子，推荐）/ `x25519`（传统） |
| 6d | **Encryption 专属**：外观 | `native` | `native` / `xorpub` / `random`（越靠后越隐蔽） |
| 6e | **Encryption 专属**：RTT | `0rtt` | `0rtt`（更快）/ `1rtt`（更安全） |
| 6f | **Encryption 专属**：Ticket 时长 | `600`（秒） | 仅 `0rtt` 模式生效 |
| 7 | 落地方式 | — | `直接落地` / `socks5 落地`（后者需填 IP、端口、用户、密码） |

> 小贴士：`apt-get install -y whiptail` 可获得对话框式交互，避免长选项敲错。

## 用法示例

> 下例中的提示文字与脚本实际输出一致；**直接回车 = 采用默认值**。

### 例 1：全新 VPS 部署 REALITY（最短路径）

```bash
# 0) 准备（Debian 12/13，root）
apt-get update && apt-get install -y wget openssl unzip
apt-get install -y whiptail        # 可选：获得对话框式交互

# 1) 下载并运行
wget -O /root/xray.sh https://raw.githubusercontent.com/shirasawatop/xray-vless-reality-install/main/xray-vless-reality-install.sh
bash /root/xray.sh
```

交互应答（只有前两项需要动手，其余回车即可）：

| 提示 | 输入 | 说明 |
|---|---|---|
| `请选择协议:` → `请输入 (1/2):` | `1` | 1 = REALITY |
| `是否优先使用 IPv6 出口？(y/n, 默认 y):` | 回车 | **空 = 是**；只填 IPv4 也不影响 |
| `请选择IPv4出口地址:` | `1` | 1 = 使用检测到的地址 |
| `请选择IPv6出口地址:` | `3` | 3 = 不使用 IPv6 出口（无 IPv6 时选此项） |
| `开启 DDNS 自动更换 IP？(y/n):` | 回车 | 空 = 否 |
| `开启 MTU 调整？(y/n):` | `n` | 隧道环境可改 `y` + MTU `1390` |
| `监听IP (默认0.0.0.0):` | 回车 | 默认即可（亦可用 `::` 走双栈） |
| `监听端口 (默认443):` | 回车 | 443 需要 `CAP_NET_BIND_SERVICE`（脚本已处理） |
| `伪装域名 (默认www.fastly.com):` | 回车 或 **`tesla.com`** | 回车即用默认 `www.fastly.com`；也可填你自测可用的站点（见下方说明） |
| `选择 (默认 chrome):` | 回车 | 客户端指纹 `fp` |
| `选择落地方式:` | `1` | 1 = 直接落地 |

结束时脚本会打印：`[✓]` 四项自检 + **IPv4 订阅链接** + 管理命令清单。

> **伪装域名（`dest`）怎么选**
>
> - 硬性条件只有一条：**你的 VPS 能与它完成 TLS1.3 握手**。REALITY 是把 ClientHello 透明转发给 `dest`、用它的真实证书完成握手，
>   **HTTP 层返回什么都不影响可用性**（返回 403 也一样）。
> - ⚠️ **不要在 VPS 上判断 h2**：CDN（Akamai 等）常对数据中心 IP 直接返回 403 并**把 ALPN 降级为 http/1.1**，会得出错误结论。
>   实测对比：`tesla.com` 从 VPS 看是「无 h2 + 403」，但在普通网络的浏览器里 `window.chrome.loadTimes().npnNegotiatedProtocol` = **`h2`**。
> - 要确认 h2，请在**普通网络**上用浏览器：DevTools → Network → 打开 **Protocol** 列查看；或 Console 执行 `window.chrome.loadTimes().npnNegotiatedProtocol`。
> - 建议：选**境外**、**非自有**、内容稳定的站点；若域名会 301/302，**直接填跳转后的最终域名**。
> - 本项目的取值：脚本默认 **`www.fastly.com`**；常用 **`tesla.com`**（历史默认值，长期在用）。
> - VPS 侧自检（**只需要第一条**）：
>
> ```bash
> openssl s_client -connect tesla.com:443 -tls1_3 </dev/null 2>/dev/null | grep -m1 'New, TLSv1.3'   # 有输出 = TLS1.3 握手 OK
> curl -sI https://tesla.com | head -1          # 403/200 都不影响 REALITY，仅供了解
> ```
>

### 例 2：部署 VLESS Encryption（抗量子）

同例 1，但协议选 `2`，并多出 4 个提问：

| 提示 | 推荐输入 | 说明 |
|---|---|---|
| 密钥模式 | `1` | `mlkem768`（抗量子）；`2` = `x25519` |
| 外观 | `1` | `native` 性能最好；`xorpub` / `random` 更隐蔽 |
| RTT | `1` | `0rtt` 更快；`2` = `1rtt` 更安全 |
| `Ticket 时长秒数（默认600，仅0rtt模式生效）:` | 回车 | 空 = `600s` |

输出的链接形如 `vless://<uuid>@<ip>:<port>?encryption=mlkem768x25519plus.native.0rtt.<客户端密钥>&…`。

### 例 3：socks5 落地 + DDNS + MTU（进阶）

落地方式选 `2`，随后填写上游 socks5 的 `IP / 端口 / 用户 / 密码`；DDNS 与 MTU 均答 `y`。DDNS 会生成
`/var/xray/ddns_check.sh` 与 `/var/xray/ddns.config`（**定时任务需自行添加**）：

```bash
# 每 5 分钟检查一次出口 IP 是否失效（示例）
echo '*/5 * * * * root /var/xray/ddns_check.sh >/dev/null 2>&1' > /etc/cron.d/xray-ddns
```

### 例 4：日常运维

```bash
xray.status                 # 服务状态 + 端口监听 + 两个进程
xray.log -f                 # 实时日志（透传 journalctl 参数）
xray.restart                # 重启服务
xray.chaguuid               # 更换客户端 UUID（会打印新的订阅链接）
```

> ⚠️ `xray.chaguuid` 换 UUID 后**所有旧客户端立即失效**，需用新链接更新客户端；命令内部会先用
> 「白名单 / 长度 / 与 config.json 一致性 / 元字符转义」四重校验，异常时拒绝执行。

### 例 5：手工调整（不重跑脚本）

```bash
cp -a /var/xray/config.json /root/config.json.bak-$(date +%F)   # 先备份
vim /var/xray/config.json                                       # 改端口 / 加客户端等
/var/xray/xray -test -c /var/xray/config.json                   # 关键：语法与语义校验，期望 "Configuration OK."
xray.restart
```

要点：

- 配置文件为 `root:xrayuser 640`，`sed -i` 会保留该归属（已验证），无需事后修权限；
- **REALITY 加客户端**：复制 `inbounds[].settings.clients` 里的一条，换一个新的 `id`（`/var/xray/xray uuid` 生成）即可 —— `pbk`/`sid`/`sni` 不变，新链接仅 `uuid` 不同；
- **Encryption 换密钥对**：用 `/var/xray/xray vlessenc` 生成新的 decryption/encryption 对，服务端改 `decryption`，客户端用对应的 `encryption` 串；
- 多个设备**共用同一 UUID** 是最省事的做法（本脚本默认形态）。

### 例 6：客户端核对（REALITY）

链接里的每个参数都能在服务端对上号，排障时按此核对：

| 链接参数 | 含义 | 服务端来源 |
|---|---|---|
| `<uuid>` | 客户端 ID | `config.json` 的 `"id"`（= `/var/xray/uuid.txt`） |
| `sni` / `host` | 伪装域名 | `realitySettings.serverNames[0]` |
| `pbk` | REALITY 公钥 | 由 `privateKey` 派生：`/var/xray/xray x25519 -i <privateKey>` |
| `sid` | shortId | `realitySettings.shortIds[0]` |
| `fp` | 客户端指纹 | 安装时所选（默认 `chrome`） |

### 例 7：更新脚本本体 / 卸载重装

```bash
# 更新脚本文件本身：只影响「下次全新安装」，不动已在跑的实例
wget -O /root/xray.sh https://raw.githubusercontent.com/shirasawatop/xray-vless-reality-install/main/xray-vless-reality-install.sh

# 备份 → 卸载 →（需要时）重装
cp -a /var/xray /root/xray.bak-$(date +%F)
xray.delxray                # 需输入 yes 确认（会停止服务、禁用自启、删除 /var/xray 与 xrayuser）
bash /root/xray.sh
```

> ⚠️ **不要在已部署的机器上直接重跑脚本**：它会重新生成密钥与 UUID（现有客户端全部失效）。脚本已内置二次确认，但请把它当"装机脚本"而不是"升级脚本"用。
> 当前版本不支持命令行参数静默安装；如需无人值守，请在受控环境里用 `expect`/管道喂入应答，并注意重复安装保护需要显式输入 `yes`。

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
| 目录 `/var/xray` | `755` | **`root:root`** | 安装收尾（阶段 20）收归 `root`：服务账户不再能重建目录内文件；运行期需写的文件已预建并留给 `xrayuser` |

**其它位置**：

| 路径 | 说明 |
|---|---|
| `/etc/systemd/system/xray_service.service` | systemd 单元（`User=xrayuser` + `AmbientCapabilities`） |
| `/usr/bin/xray.*`、`/usr/local/bin/xray.*` | 管理命令符号链接（`xray.chaguuid`、`xray.status` 等） |

> **权限模型的设计意图**：服务以低权账户 `xrayuser` 运行，但**二进制与入口脚本归 `root`**，避免"低权账户可写、root 可执行"这一经典提权组合；`config.json` 与含密钥的脚本只给到必要的读权限。**目录亦已收归 `root`** —— 只把运行期产物（`xray.pid` / `sni-filter.pid` / `statusfilter` / `socket/`）留给服务账户。请勿随意放宽上述权限。

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
- 安装收尾会执行**目录收口**：`/var/xray` → `root:root 755`，并把运行期文件预建给 `xrayuser` —— 避免「低权账户可 `unlink` 并重建 root 文件」的完整性面（DDNS 形态除外，见「已知限制」）。
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
| realtime sni-filter **v0.2** | `github.com/shirasawatop/REALITY-sni-filter` releases —— **本项目 fork，上游 [oldfriendme/REALITY-sni-filter](https://github.com/oldfriendme/REALITY-sni-filter)（MIT）** | **仅 REALITY 形态**：443 监听者 |
| `cloudflare.com/cdn-cgi/trace` | Cloudflare | 探测公网 IPv4 / IPv6 |

## 已知限制

1. 仅在 Debian 12/13（systemd）实测；其它发行版可能需要自行适配。
2. Xray 版本在脚本内**硬编码**（`v26.3.27`，3 处 URL），升级需手动改。
3. DDNS 只生成脚本并执行一次，**定时调度需自行挂 cron / systemd timer**。
4. 安装后只验证**服务端**（服务状态、端口、进程）；真实客户端连通性请自行测试。
5. 未启用 `set -u`（脚本内可选变量较多，逐条排查成本较高）。
6. `config.json` 的属主为 `xrayuser` 还是 `root:xrayuser` 取决于部署时的版本；本版本使用后者。
7. **DDNS 与「目录收口」互斥**：启用 DDNS 时脚本会跳过 `/var/xray` 的目录收口（原因见「变更记录 v1.0.3」）。若既要 DDNS 又要收口，请把 `ddns_check.sh` 交给 **root** 的 cron / systemd timer 运行（例 3 已给出 cron 写法），并确认 `xrayinit` 里不再由服务账户调用它。

## 变更记录

**v1.0.3（2026-09-12）**

- **新增阶段 20「权限收口（目录完整性面）」**：安装收尾把 `/var/xray` 目录由 `xrayuser:xrayuser` 收归 **`root:root` `755`**，并把运行期需要写入的文件（`xray.pid`、`statusfilter`；REALITY 形态另加 `sni-filter.pid`）**预建**并留给 `xrayuser`；`socket/` 仍归 `xrayuser`。
  - 修复的问题：目录可写 ⇒ 即使二进制 / 入口脚本已归 `root`，服务账户仍可 `unlink` **并重建**它们，构成「低权账户先落地、等管理员执行 `xray.chaguuid`」的提权链（`chaguuid` 以 root 执行 `/var/xray/xray`）。
  - 处置顺序：**先预建运行期文件、再收目录**（顺序颠倒会让服务账户无法再创建 pid 文件）。
- **DDNS 与目录收口互斥**：DDNS 由 `xrayinit`（`xrayuser` 身份）调用 `ddns_check.sh`，其重写 `config.json` 依赖目录写权限（`sed -i` = 同目录临时文件 + rename）。启用 DDNS 时脚本**跳过目录收口并打印警告**；如需同时收口，请改用 root 定时器运行 `ddns_check.sh`（见「已知限制」第 7 条）。
- 头部「权限模型」注释与 README 权限表同步更新；**无其它行为变更**。

**v1.0.2（2026-09-11）**

- **默认伪装域名**由 `tesla.com` 改为 **`www.fastly.com`** —— 实测（从服务端发起）：TLS1.3 + HTTP/2 + HTTP 200、握手约 20 ms。
- `tesla.com` 仍是**可用**选项：它的 HTTP 层对数据中心 IP 返 403，但 TLS1.3 握手正常 —— REALITY 只用握手，故不受影响（此前把 403 当作"不可用"的表述已更正）。
- README 的伪装域名示例与判据说明同步更新；无其它功能变更。
- **h2 判据更正**：不要用 VPS 判断 h2 —— CDN 对数据中心 IP 会返回 403 并把 ALPN 降级为 http/1.1；`tesla.com` 在真实浏览器上实测 `npnNegotiatedProtocol = h2`。

**v1.0.1（2026-09-11）**

- **署名更正**：REALITY 形态使用的 `sni-filter` 系 **[oldfriendme/REALITY-sni-filter](https://github.com/oldfriendme/REALITY-sni-filter)（MIT）的 fork** —— README 与脚本内均已标注上游来源，感谢原作者。
- 无功能变更（仅文档与注释）。

**v1.0.0（2026-09-11）** —— 首次公开发布

- 二合一部署：REALITY（+ sni-filter）/ VLESS Encryption。
- 权限模型收紧：`uuid.txt`/`encryption_key.txt` → `600`（含 `chaguuid` 内部重写路径）；`config.json` → `640 root:xrayuser`；`chaguuid` → `700`；`xray`/`sni-filter`/`xrayinit` → `root` 所有（**修掉"低权账户可写、root 可执行"的提权路径**）。
- `chaguuid` 修复 `sed` 注入面（输入白名单 / 长度 / 定点存在性 / 元字符转义），并顺带修复 `uuid.txt` 与 `config.json` 不一致时仍打印订阅链接的问题。
- 新增前置检查：root 身份、依赖检查（含安装提示）、重复安装二次确认。
- `xrayhelp` 命令名笔误修正（`xray.chuuid` → `xray.chaguuid`）；`delxray` 增加二次确认。

## 许可

**MIT License** ｜ Copyright (c) 2026 [shirasawatop](https://github.com/shirasawatop) ｜ 全文见 [`LICENSE`](./LICENSE)

- 可自由使用、修改、分发，需保留版权与许可声明。
- REALITY 形态会下载 [`REALITY-sni-filter`](https://github.com/shirasawatop/REALITY-sni-filter) —— 该组件是 **[oldfriendme/REALITY-sni-filter](https://github.com/oldfriendme/REALITY-sni-filter)（MIT）的 fork**，感谢原作者；其许可遵循上游仓库，Xray-core 版权归 [XTLS/Xray-core](https://github.com/XTLS/Xray-core) 所有。
