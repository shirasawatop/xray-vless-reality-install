# xray-vless-reality-install

> Debian 12/13 上一键部署 Xray 服务端，支持 **REALITY（+ sni-filter）** 与 **VLESS Encryption** 两种形态，带成体系的文件权限模型与一套管理命令。
> *One-command installer for Xray on Debian: **VLESS over REALITY (with sni-filter)** or **VLESS-Encryption**, with a hardened file-permission model and a full set of management commands.*

| 项 | 值 |
|---|---|
| 当前版本 | **v1.1.0（2026-09-21）** |
| 目标系统 | Debian 12 / 13（systemd） |
| 脚本 | [`xray-vless-reality-install.sh`](./xray-vless-reality-install.sh) |
| 配套脚本 | [`enable-xray-stats.sh`](./enable-xray-stats.sh) —— 为**既有部署**幂等补装流量统计（可回滚，不重装） |
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
- **运行期文件自愈**：服务单元的 `ExecStartPre` 会在每次启动（含开机）重建 `xray.pid` / `sni-filter.pid` / `statusfilter` 并交还 `xrayuser` —— 配合「目录收归 `root`」，误删也不会卡住服务。
- 可选：IPv4/IPv6 出口选择与优先顺序、DDNS 检测脚本、MTU 调整（经 unit 的 `ExecStartPre` 生效）、socks5 落地。
- **流量统计（v1.1.0，安装时询问 / 默认开启）**：生成 `stats` + `api(StatsService)` + `policy`（用户级与入站级计数）、api 入站（**仅监听 `127.0.0.1:<apiport>`，默认 10085**，公网不可达）、主入站 `tag`（默认 `vless-in`）与首个客户端 `email`（默认 `client-1`）—— 之后用 `xray.stats` 即可查看用量。**关闭该项则完全不生成相关配置**（与 v1.0.4 等价）。
- **API 路由规则置于 `routing.rules` 首位**（不变量）：脚本生成的 `direct-ipv4/ipv6` 规则**不限定入站**，若 api 规则排在其后会被截走 ⇒ 统计**静默失效**；故安装收尾会**实测** `statsquery`（端口在听 ≠ 查询可用）。

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
| 6.5 | **是否启用流量统计** | `Y`（**默认开启**） | `Y` → 追加 `stats`/`api`/`policy` 与 api 入站（**仅 `127.0.0.1`**）；`n` → 完全不生成（等价 v1.0.4） |
| 6.5a | 统计 API 端口 | `10085` | 仅回环监听；校验 >1024 且 ≠ 主监听端口；被**第三方**占用则自动向上找空位（占用者是**本机既有 xray** 时保持端口，阶段 18 重启即释放） |
| 6.5b | 客户端统计名 `email` | `client-1` | 决定计数键名 `user>>>client-1>>>traffic>>>…`；主入站 `tag` 固定为 `vless-in` |
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
| `启用？(Y/n，默认 Y):` | 回车 | **流量统计默认开启**（回车即启用；答 `n` 则完全不生成） |
| `统计 API 端口（仅回环，默认 10085）:` | 回车 | 仅 `127.0.0.1` 可达，公网不可达 |
| `客户端统计名 email（默认 client-1）:` | 回车 | 决定计数键名 `user>>>client-1>>>…` |
| `选择落地方式:` | `1` | 1 = 直接落地 |

结束时脚本会打印：`[✓]` **六项**自检（v1.1.0 起含「统计 API 已监听」与「`statsquery` 实测可查询」）+ **IPv4 订阅链接** + 管理命令清单。

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
`/var/xray/ddns_check.sh`、`/var/xray/ddns.config`，以及 **`xray-ddns.service` + `xray-ddns.timer`
（systemd，每 `60s` 一次，以 root 运行）** —— 安装时即启用，**无需手工添加定时任务**：

```bash
systemctl list-timers xray-ddns.timer    # 下次触发时间
systemctl status xray-ddns.service       # 单次执行的退出状态（oneshot）
journalctl -u xray-ddns.service -n 50    # 执行日志
```

> **为什么以 root 运行**：`ddns_check.sh` 需要重写 `config.json`（`sed -i` = 同目录临时文件 + 重命名），
> 因此需要 `/var/xray` 的目录写权限；交给 root 后，`/var/xray` 依然可以安全地收归 `root:root`（阶段 20）。
> 若你更习惯 cron，可自行加一条 **root** 的 cron（`* * * * * root /var/xray/ddns_check.sh`）并停用该 timer。

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
| `xraystats` | `755` | `root:root` | **仅启用流量统计时生成**；查询用量（不含内联密钥，故无需 `700`） |
| `socket/`、`xray.pid`、`sni-filter.pid`、`statusfilter` | — | `xrayuser:xrayuser` | 运行期产物 |
| 目录 `/var/xray` | `755` | **`root:root`** | 安装收尾（阶段 20）收归 `root`：服务账户不再能重建目录内文件；运行期需写的文件已预建并留给 `xrayuser` |

**其它位置**：

| 路径 | 说明 |
|---|---|
| `/etc/systemd/system/xray_service.service` | systemd 单元（`User=xrayuser` + `AmbientCapabilities`） |
| `/usr/bin/xray.*`、`/usr/local/bin/xray.*` | 管理命令符号链接（`xray.chaguuid`、`xray.status` 等） |

> **运行期文件自愈**：`xray.pid` / `sni-filter.pid` / `statusfilter` 由单元 `ExecStartPre` 在每次启动（含开机）重建并 `chown xrayuser` —— 被误删时 `systemctl restart xray_service` 即可恢复，无需手工 `touch`。

> **权限模型的设计意图**：服务以低权账户 `xrayuser` 运行，但**二进制与入口脚本归 `root`**，避免"低权账户可写、root 可执行"这一经典提权组合；`config.json` 与含密钥的脚本只给到必要的读权限。**目录亦已收归 `root`** —— 只把运行期产物（`xray.pid` / `sni-filter.pid` / `statusfilter` / `socket/`）留给服务账户。请勿随意放宽上述权限。

## 管理命令

| 命令 | 作用 |
|---|---|
| `xray.status` | 查看服务状态、端口监听与两个进程 |
| `xray.start` / `xray.stop` / `xray.restart` | 启停 / 重启服务 |
| `xray.log` | 最近 50 行服务日志（支持 `-f` 等 `journalctl` 参数） |
| `xray.stats` | **流量统计查询**（v1.1.0，启用统计时才有）：`xray.stats` / `xray.stats user` / `xray.stats inbound` / `xray.stats user -r`（读后清零） |
| `xray.chaguuid` | **更换客户端 UUID**（改 `config.json` 并重启，随后打印新订阅链接） |
| `xray.help` | 命令一览 |
| `xray.delxray` | **卸载**（停止并禁用服务、删除 `/var/xray` 与 `xrayuser`；需输入 `yes` 确认） |

## 流量统计（v1.1.0+）

安装时选择启用（**默认开启**）后，`config.json` 会多出 `stats` / `api` / `policy` 三项、一个**仅回环**的 api 入站，以及主入站 `tag` 与客户端 `email`；随后即可按客户端、按入站查看用量：

```bash
xray.stats              # 全部统计项（JSON）
xray.stats user         # 仅按客户端（email）
xray.stats inbound      # 仅按入站
xray.stats user -r      # 读取后清零（适合做周期差值采集）
```

计数键名（`user>>>` 为**纯载荷**口径，`inbound>>>` 更接近网络字节）：

| 键 | 含义 |
|---|---|
| `user>>>client-1>>>traffic>>>uplink/downlink` | 该客户端的**载荷**收发（业务报表用这个） |
| `inbound>>>vless-in>>>traffic>>>uplink/downlink` | 主入站收到的字节（含 VLESS/REALITY 协议头，与网卡口径更接近） |
| `inbound>>>api>>>traffic>>>…` | 统计查询自身产生的流量（可忽略） |
| `outbound>>>direct-…>>>traffic>>>…` | 各出口的出站量 |

> ⚠️ **统计是内存态**：重启 `xray_service` 即归零，脚本**不做任何落盘**。需要长期留存/月报请自加定时采集，例如：
>
> ```bash
> # root 的 cron（示例：每分钟落盘一次并清零）
> * * * * * root /var/xray/xraystats -r > /var/log/xray-stats/$(date +\%Y\%m\%d\%H\%M).json
> ```

> **既有部署补装统计**：不想重装（重装会换密钥/UUID）时用配套脚本 —— 幂等、自动备份、写入前打印差异、失败**自动回滚**，并带**真实流量端到端自测**：
>
> ```bash
> ./enable-xray-stats.sh --check      # 只体检，不做任何改动
> ./enable-xray-stats.sh --dry-run    # 预览将要写入的差异
> ./enable-xray-stats.sh -y           # 执行（-p 改端口 / -e 改统计名 / -w 改工作目录）
> ./enable-xray-stats.sh --reformat -y   # 仅重排为规范形态（语义等价断言后不重启）
> ./enable-xray-stats.sh --rollback   # 回滚到最近一次备份并重启
> ```
>
> 两种形态（REALITY / VLESS Encryption）自动识别；`--check` 也可用于日常巡检「统计是否仍然生效」。

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

# 运行期文件自愈（v1.0.4+）：删掉后重启应自动重建并归属 xrayuser
rm -f /var/xray/xray.pid && systemctl restart xray_service && ls -l /var/xray/xray.pid

# 流量统计（v1.1.0+，启用时）
ss -tlnp | grep ':10085\b'                                      # api 仅监听 127.0.0.1
/var/xray/xray api statsquery --server=127.0.0.1:10085 -pattern ''   # 或直接 xray.stats
python3 -c "import json;print(json.load(open('/var/xray/config.json'))['routing']['rules'][0])"   # api 规则须在首位

# DDNS 定时器（仅启用 DDNS 时存在）
systemctl list-timers xray-ddns.timer 2>/dev/null || echo "未启用 DDNS"
```

| 现象 | 排查方向 |
|---|---|
| 提示缺少 `unzip`/`wget`/`openssl` | 按提示 `apt-get install -y …` 后重跑 |
| 端口未监听 | `journalctl -u xray_service -n 50`；确认端口未被占用（`ss -tlnp \| grep :443`） |
| REALITY 形态看不到 `xray` 监听 443 | **正常**：443 由 `sni-filter` 监听，xray 走 unix socket |
| 客户端连不上 | 核对链接里的 `uuid`、`sni/host`、`pbk`、`sid`、`fp` 是否与安装输出一致；确认客户端时间准确 |
| 重跑安装脚本后客户端全失效 | 预期行为：重跑会**重新生成密钥与 UUID**（脚本已二次确认）；请用新链接更新客户端 |
| `xray.stats` 报 `failed to dial 127.0.0.1:10085` | 统计未启用或端口被改：`ss -tlnp \| grep 10085`；核对 `config.json` 的 api 入站端口与查询命令是否一致 |
| 统计项一直是空值 | 检查 `routing.rules[0]` 是否为 `{"inboundTag":["api"],"outboundTag":"api"}` —— 该规则**必须在首位**，否则查询会被 `direct-*` 规则截走 |

## 安全说明

- **不做任何数据回传/遥测**。脚本只访问：`github.com`（Xray 与 sni-filter 发布页）、`cloudflare.com`（探测公网 IP）。
- **重跑会重新生成 REALITY 密钥与 UUID 并覆盖 `config.json`** ⇒ 现有客户端立即失效（脚本已内置二次确认）。
- `xray.chaguuid` 会更换 UUID，**所有客户端需同步更新**；`xray.delxray` 为破坏性操作（`rm -rf /var/xray`）并需 `yes` 确认。
- `chaguuid` 换 UUID 时的 `sed` 替换已做**输入白名单 + 长度 + 定点存在性 + 元字符转义**四重校验，避免恶意 `uuid.txt` 内容注入 `sed` 命令（历史上这类写法可导致 root 命令执行）。
- 安装收尾会执行**目录收口**：`/var/xray` → `root:root 755`，并把运行期文件预建给 `xrayuser` —— 避免「低权账户可 `unlink` 并重建 root 文件」的完整性面（v1.0.4 起 DDNS 形态同样适用，见「已知限制」第 7 条）。
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
3. DDNS 会生成 `ddns_check.sh`，并**自动安装并启用** `xray-ddns.service` + `xray-ddns.timer`（每 `60s`，以 root 运行）；仅当你停用该 timer 时，才需要自行挂 cron / systemd timer 兜底。
4. 安装后只验证**服务端**（服务状态、端口、进程）；真实客户端连通性请自行测试。
5. 未启用 `set -u`（脚本内可选变量较多，逐条排查成本较高）。
6. `config.json` 固定为 **`640 root:xrayuser`**（服务账户只经 group 位读取）。若你的部署来自早期版本（属主为 `xrayuser`），一条命令即可统一 —— 内容不变，且 `sed -i` 会保留新归属（实测：`640 root:xrayuser` 经 `sed -i` 后**归属与 md5 均不变**）：

   ```bash
   chown root:xrayuser /var/xray/config.json && chmod 640 /var/xray/config.json
   ```
7. **DDNS 刻意以 root 运行**（`xray-ddns.timer` → `ddns_check.sh`）：这样 `/var/xray` 才能保持 `root:root` 收口。若你改成非 root 运行，需自行放宽目录权限（不建议，会重新打开「低权账户可 unlink + 重建 root 文件」的完整性面）。
8. **流量统计为内存态**：重启服务即归零，脚本**不落盘**；要长期留存请自加定时采集（见「流量统计（v1.1.0+）」一节）。
9. 统计的 api 入站固定绑定 **`127.0.0.1`**（有意为之：不暴露公网、无需改防火墙）。需要远程拉取统计时请用 SSH 隧道（`ssh -L 10085:127.0.0.1:10085 <user>@<host>`），**不要**改成 `0.0.0.0`。
10. 统计依赖两条**手工编辑易破坏**的不变量：① `routing.rules[0]` 必须是 api 规则；② api 入站 `port` 须与查询命令一致。改完配置请务必 `xray.restart` 后执行 `xray.stats` 实测。
11. 统计**只反映本机 xray 的用量**（不是网卡口径）；与 `vnstat` 等网卡统计对账时请用 `inbound>>>` 键，二者仍会因重传/协议开销存在几个百分点的差异。

## 变更记录

**v1.1.0（2026-09-21）**

- **新增「流量统计（Stats/API）」**：安装时询问、**默认开启**。生成 `stats` + `api(StatsService)` + `policy`（`statsUserUplink/Downlink` 与 `statsInbound/Outbound*`）、一个**仅回环**的 api 入站（`127.0.0.1:<apiport>`，默认 `10085`），并给主入站加 `tag`（默认 `vless-in`）、给首个客户端加 `email`（默认 `client-1`）⇒ 计数键名可读。
  - **不变量**：api 路由规则必须位于 `routing.rules` **首位**。脚本生成的 `direct-ipv4/ipv6` 规则**不限定入站**，若 api 规则排在其后会截走本地查询 ⇒ 统计**静默失效**。`generate_routing()` 已改为统一在首位拼接 api 规则。
  - 新增管理命令 **`xray.stats`**（`xraystats`，`755 root:root`，不含内联密钥）；`xrayhelp` / `xraystatus` 同步展示统计端口。
  - 阶段 19 新增**两项实测自检**（api 端口监听 + `statsquery` 可查询）—— 该特性属于「端口在听但查询不通」的**静默失败型**，只查端口不够。
- **修复：重跑安装时新配置不被加载**（严重，实机复现）—— 阶段 18 原用 `systemctl start`，对**已 active** 的单元是 no-op：在已有部署上重跑（脚本明确支持、且提示需答 `yes`）后，进程继续使用**旧 UUID/密钥/api 端口**，而阶段 21 打印的是**新订阅链接** ⇒ 客户端全部连不上，且端口检查会因旧进程监听而「假成功」。**改为 `systemctl restart`**（对未启动单元等价于 start，新装/重跑均正确）。
- **修复：REALITY 订阅链接 `pbk` 为空**（严重，实机复现）—— Xray 26.3.27 的 `xray x25519` 输出标签已变为 `Password (PublicKey):`，而旧代码 `grep "Password:"` 取不到值 ⇒ 链接形如 `&pbk=&sid=…`，**客户端全部连不上**（而安装过程全部显示 ✓）。改为「行首标签(允许后缀): 值」的宽松解析并**显式校验非空**（REALITY 与 Encryption-x25519 分支均已修正，解析失败即终止安装）。
- **统计 API 端口占用处理**：被**第三方**进程占用时自动向上寻找空位；占用者是**本机既有 xray**（重跑场景）时保持端口不变（阶段 18 的 restart 会释放），避免每次重跑端口 +1 漂移。
- **新增配套脚本 [`enable-xray-stats.sh`](./enable-xray-stats.sh)**：为既有部署**幂等**补装统计（自动备份、写入前差异预览、失败**自动回滚**、真实流量端到端自测），支持 `--check` / `--dry-run` / `--rollback`，自动识别两种形态。
- **校验记录**：在 Debian 13 实机完成 **REALITY 与 VLESS Encryption 两种形态的完整安装 + 重跑覆盖**验证（阶段 19 全部 ✓；真实流量自测 HTTP 204 且 `user>>>` 计数非零；`pbk` 与由 `privateKey` 派生的公钥一致；`xray.stats` 返回全部 10 个计数键）。
- 头部「权限模型」注释、README（特性 / 交互流程 / 例 1 / 生成物 / 管理命令 / 新增「流量统计」节 / 排障 / 已知限制）同步更新。

**v1.0.4（2026-09-12）**

- **DDNS 定时改由 root 的 systemd timer 驱动**（新增 `xray-ddns.service` + `xray-ddns.timer`，每 `60s`）：
  - `xrayinit` 不再内嵌「每 60 s 调 `ddns_check.sh`」的循环（改为恒定驻留循环，仅用于保活）；
  - `ddns_check.sh` 的重启动作由 `kill + setsid` 改为 **`systemctl restart xray_service`**（避免以 root 拉起服务进程）；
  - **因此 DDNS 形态不再豁免目录收口**（废除 v1.0.3 的例外）。
- **服务单元新增「运行期文件自愈」**：`ExecStartPre=+/bin/sh -c 'touch …; chown xrayuser …'` ——
  `xray.pid` / `sni-filter.pid` / `statusfilter` 被误删后，`systemctl restart`（或机器重启）即自动重建并交还 `xrayuser`。
- 头部「权限模型」注释、README（特性 / 例 3 / 已知限制 / 排障）同步更新；**无其它行为变更**。

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
