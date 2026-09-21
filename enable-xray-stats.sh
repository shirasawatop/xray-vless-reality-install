#!/bin/bash
# ============================================================================
# enable-xray-stats.sh — 为已部署实例补装 Xray 流量统计（Stats/API） v1.0
# ----------------------------------------------------------------------------
# 用途：本项目 xray-vless-reality-install.sh（v1.0.4 及更早）生成的 config.json
#       不含 stats/api，无法按客户端或按入站查看用量。本脚本以**幂等**方式补齐，
#       面向**既有部署**；新装请直接用 v1.1.0+ 安装脚本（已内置，默认开启）。
#
# 支持形态（自动识别）：
#   ① REALITY        —— xray 走 unix socket，sni-filter 监听 443
#   ② VLESS Encryption —— xray 直接监听 443
#
# 关键约束（勿改）：
#   1) api 路由规则必须位于 routing.rules **首位**：安装脚本生成的路由里存在
#      {"outboundTag":"direct-ipv4","ip":["0.0.0.0/0"]} 这类**不限定入站**的规则，
#      若 api 规则排在其后，本地统计请求会被转发到 direct-*，statsquery 将不通。
#   2) api 入站仅监听 127.0.0.1（公网不可达）；防火墙无需新增放行
#      （加固模板已有 `iif "lo" accept`）。
#   3) 统计为**内存态**：重启 xray_service 即归零；需长期留存请另加定时落盘。
#   4) API 端口需 >1024 且不等于主监听端口（服务仍以 xrayuser 运行，不新增 capability）。
#
# 安全性：写入前备份 → 写入前打印语义差异 → 免确认需显式 -y → `xray -test` 预检
#         → 重启后五项自检 → 任一环节失败**自动回滚**。
#
# 用法：
#   ./enable-xray-stats.sh [选项]
#     -w DIR       工作目录，默认 /var/xray
#     -p PORT      API 端口（仅回环），默认 10085
#     -e NAME      客户端统计名（email），默认 client-1
#     -t TAG       主 vless 入站 tag，默认 vless-in
#     -y           免交互确认
#     --dry-run    只打印将要做的改动，不写入、不重启
#     --reformat   仅重排为**规范形态**（canonical JSON：固定顶层键序 + 2 空格缩进）；
#                  语义等价断言通过后**不重启服务**（用于把手工编辑过的 config 收敛为标准形态）
#     --no-selftest 跳过真实流量自测
#     --check      只检查现状（幂等自检），不做任何改动
#     --rollback   回滚到最近一次 .bak-stats-* 备份并重启
# ============================================================================
set -euo pipefail

WORKDIR=/var/xray
APIPORT=10085
EMAIL=client-1
INTAG=vless-in
ASSUME_YES=no
DRY_RUN=no
SELFTEST=yes
REFORMAT=no
MODE=apply
SVC=xray_service

C_RED='\e[31m'; C_GREEN='\e[32m'; C_YELLOW='\e[33m'; C_NC='\e[0m'
info(){ echo -e "${C_GREEN}[✓]${C_NC} $*"; }
warn(){ echo -e "${C_YELLOW}[!]${C_NC} $*"; }
die(){ echo -e "${C_RED}[✗]${C_NC} $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -w) WORKDIR="$2"; shift 2;;
        -p) APIPORT="$2"; shift 2;;
        -e) EMAIL="$2"; shift 2;;
        -t) INTAG="$2"; shift 2;;
        -y) ASSUME_YES=yes; shift;;
        --dry-run) DRY_RUN=yes; shift;;
        --reformat) REFORMAT=yes; shift;;
        --no-selftest) SELFTEST=no; shift;;
        --check) MODE=check; shift;;
        --rollback) MODE=rollback; shift;;
        -h|--help) sed -n '2,40p' "$0"; exit 0;;
        *) die "未知参数: $1（-h 查看用法）";;
    esac
done

CONFIG="$WORKDIR/config.json"
XRAY="$WORKDIR/xray"

[ "$(id -u)" -eq 0 ] || die "请以 root 运行（需写 config.json 与重启服务）"
case "$APIPORT" in ''|*[!0-9]*) die "API 端口必须是数字";; esac
{ [ "$APIPORT" -ge 1024 ] && [ "$APIPORT" -le 65535 ]; } || die "API 端口需在 1024-65535"

# ---------------------------------------------------------------- 回滚分支
if [ "$MODE" = rollback ]; then
    latest=$(ls -1t "$WORKDIR"/config.json.bak-stats-* 2>/dev/null | head -1 || true)
    [ -n "$latest" ] || die "未找到任何 $WORKDIR/config.json.bak-stats-* 备份"
    info "回滚目标: $latest"
    cp -a "$latest" "$WORKDIR/.rollback.tmp" && cat "$WORKDIR/.rollback.tmp" > "$CONFIG" && rm -f "$WORKDIR/.rollback.tmp"
    systemctl restart "$SVC"
    sleep 2
    systemctl is-active --quiet "$SVC" && info "已回滚并重启（md5: $(md5sum "$CONFIG" | awk '{print $1}')）" || die "回滚后服务未运行"
    exit 0
fi

[ -f "$CONFIG" ] || die "未找到 $CONFIG（用 -w 指定工作目录）"
[ -x "$XRAY" ]   || die "未找到可执行文件 $XRAY"
command -v python3 >/dev/null 2>&1 || die "缺少 python3（apt-get update && apt-get install -y python3）"
systemctl cat "$SVC" >/dev/null 2>&1 || die "未找到 systemd 单元 $SVC"

ORIG_MD5=$(md5sum "$CONFIG" | awk '{print $1}')

# 端口占用检查（幂等场景下可能是本机既有 API 监听）
BUSY=$(ss -tlnp 2>/dev/null | awk -v p=":$APIPORT\$" '$4 ~ p' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
if [ -n "$BUSY" ]; then
    if pgrep -f "$XRAY -c" | grep -qx "$BUSY"; then
        info "端口 $APIPORT 已由本机 xray 监听（视为既有 API）"
    else
        die "端口 $APIPORT 已被其它进程占用（pid=$BUSY），请用 -p 指定其它端口"
    fi
fi

# ---------------------------------------------------------------- 生成新配置
TMPNEW=$(mktemp /tmp/xray-stats-new.XXXXXX.json)
trap 'rm -f "$TMPNEW"' EXIT

set +e
REPORT=$(python3 - "$CONFIG" "$APIPORT" "$EMAIL" "$INTAG" "$MODE" "$TMPNEW" "$REFORMAT" <<'PY'
import json, sys

cfg_path, apiport, email, intag, mode, outpath = (
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
refmt = sys.argv[7] if len(sys.argv) > 7 else "no"
cfg = json.load(open(cfg_path, encoding="utf-8"))
changed, warns = [], []

def add(p): changed.append(p)

# --- stats / api ---
if cfg.get("stats") is None:
    cfg["stats"] = {}; add("/stats")
want_api = {"tag": "api", "services": ["StatsService"]}
if cfg.get("api") != want_api:
    cfg["api"] = want_api; add("/api")

# --- policy：用户级 + 系统级计数 ---
pol = cfg.setdefault("policy", {})
lv = pol.setdefault("levels", {}).setdefault("0", {})
for k in ("statsUserUplink", "statsUserDownlink"):
    if lv.get(k) is not True:
        lv[k] = True; add("/policy/levels/0/" + k)
sy = pol.setdefault("system", {})
for k in ("statsInboundUplink", "statsInboundDownlink", "statsOutboundUplink", "statsOutboundDownlink"):
    if sy.get(k) is not True:
        sy[k] = True; add("/policy/system/" + k)

# --- 主 vless 入站：tag + 首个客户端 email ---
inbounds = cfg.setdefault("inbounds", [])
main_i = next((i for i, x in enumerate(inbounds)
               if x.get("protocol") == "vless" and x.get("tag") != "api"), None)
if main_i is None:
    print("STATUS=ERROR"); print("CHANGE 未找到 vless 主入站"); sys.exit(3)
main = inbounds[main_i]
if main.get("tag") != intag:
    m = {"tag": intag}
    for k, v in main.items():
        if k != "tag": m[k] = v
    inbounds[main_i] = main = m
    add("/inbounds/%d/tag" % main_i)
clients = main.setdefault("settings", {}).setdefault("clients", [])
if not clients:
    print("STATUS=ERROR"); print("CHANGE 主入站没有任何客户端"); sys.exit(3)
if clients[0].get("email") != email:
    c = {"email": email}
    for k, v in clients[0].items():
        if k != "email": c[k] = v
    clients[0] = c
    add("/inbounds/%d/settings/clients/0/email" % main_i)
if len(clients) > 1:
    warns.append("主入站有 %d 个客户端，仅首个设置了 email；其余需各自设置 email 才能按人统计" % len(clients))

# --- api 入站（仅回环）---
api_i = next((i for i, x in enumerate(inbounds) if x.get("tag") == "api"), None)
want_ib = {"tag": "api", "listen": "127.0.0.1", "port": apiport, "protocol": "dokodemo-door",
           "settings": {"address": "127.0.0.1"}}
if api_i is None:
    inbounds.append(want_ib); add("/inbounds/%d（新增 api 入站 127.0.0.1:%d）" % (len(inbounds) - 1, apiport))
elif inbounds[api_i] != want_ib:
    inbounds[api_i] = want_ib; add("/inbounds/%d（api 入站更新为 127.0.0.1:%d）" % (api_i, apiport))

# --- routing：api 规则必须置首位 ---
routing = cfg.setdefault("routing", {})
rules = routing.setdefault("rules", [])
api_rule = {"type": "field", "inboundTag": ["api"], "outboundTag": "api"}
rest = [r for r in rules if not (r.get("outboundTag") == "api" and "api" in (r.get("inboundTag") or []))]
if rules[:1] != [api_rule] or len(rest) != len(rules) - 1:
    routing["rules"] = [api_rule] + rest
    add("/routing/rules[0]（api 规则置首位）")
    if any("inboundTag" not in r for r in rest):
        warns.append("routing 含不限定入站的规则；api 规则已置首位，请勿调整顺序")

# --- 顶层键顺序（可读性；语义无影响）---
order = ["log", "stats", "api", "policy", "inbounds", "outbounds", "routing"]
reordered = {}
for k in order:
    if k in cfg: reordered[k] = cfg[k]
for k, v in cfg.items():
    if k not in reordered: reordered[k] = v
cfg = reordered

if mode != "check" and (changed or refmt == "yes"):
    with open(outpath, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")

print("STATUS=" + ("NEEDS" if changed else "ALREADY"))
for c in changed: print("CHANGE " + c)
for w in warns: print("WARN " + w)
PY
)
RC=$?
set -e
[ $RC -eq 0 ] || die "配置分析失败（python 退出码 $RC）"

STATUS=$(printf '%s\n' "$REPORT" | sed -n 's/^STATUS=//p' | head -1)
printf '%s\n' "$REPORT" | sed -n 's/^WARN /[!] /p'
printf '%s\n' "$REPORT" | sed -n 's/^CHANGE /    + /p'

# ---------------------------------------------------------------- 幂等：已启用
if [ "$STATUS" = ALREADY ] && [ "$REFORMAT" != yes ]; then
    info "统计已启用（幂等）：未做任何改动（md5 仍为 $ORIG_MD5）"
    SKIP_APPLY=yes
elif [ "$STATUS" = ALREADY ]; then
    info "统计已启用（语义已达标）；--reformat：仅重排为规范形态（等价断言通过后**不重启**服务）"
    SKIP_APPLY=no
else
    SKIP_APPLY=no
fi

# ---------------------------------------------------------------- --check 分支
if [ "$MODE" = check ]; then
    if [ "$STATUS" = ALREADY ]; then info "检查结果: 已启用"; else warn "检查结果: 未启用（缺少上述项）"; fi
    exit 0
fi

if [ "$SKIP_APPLY" = no ]; then
    if [ "$DRY_RUN" = yes ]; then
        info "dry-run：仅预览，不写入、不重启"
        exit 0
    fi
    if [ "$ASSUME_YES" != yes ]; then
        read -rp "确认写入 $CONFIG 并重启 $SVC？(yes/no) " ans
        [ "$ans" = yes ] || die "已取消"
    fi

    # 预检新配置
    if "$XRAY" run -test -c "$TMPNEW" >/tmp/xray-stats-test.log 2>&1; then :; else
        tail -5 /tmp/xray-stats-test.log >&2
        die "新配置未通过 xray 语法/语义预检（未改动线上）"
    fi
    info "新配置预检通过（Configuration OK）"

    BAK="$CONFIG.bak-stats-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG" "$BAK"
    info "已备份: $BAK（md5 $ORIG_MD5）"

    # cat > 原地覆写：保留 inode 与 root:xrayuser 640 权限（且不依赖目录写权限）
    cat "$TMPNEW" > "$CONFIG"
    NEW_MD5=$(md5sum "$CONFIG" | awk '{print $1}')
    info "配置已写入（md5 $ORIG_MD5 → $NEW_MD5）"

    if [ "$REFORMAT" = yes ]; then
        # --reformat：只做规范化重排，语义必须完全等价 ⇒ 无需重启
        if python3 -c '
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))
b = json.load(open(sys.argv[2], encoding="utf-8"))
sys.exit(0 if a == b else 1)' "$BAK" "$CONFIG"; then
            info "语义等价断言通过：重排前后解析结果**逐键相等** ⇒ 不重启服务"
            if "$XRAY" api statsquery --server="127.0.0.1:$APIPORT" -pattern "" >/dev/null 2>&1; then
                info "运行实例不受影响（statsquery 仍可用）"
                SKIP_RESTART=yes
            else
                warn "statsquery 失败，自动回滚"
                cat "$BAK" > "$CONFIG"
                die "已回滚到 $ORIG_MD5（未重启服务）"
            fi
        else
            warn "重排前后语义不等价（不应发生），自动回滚"
            cat "$BAK" > "$CONFIG"
            die "已回滚到 $ORIG_MD5"
        fi
    fi

    if [ "${SKIP_RESTART:-no}" != yes ]; then
        systemctl restart "$SVC"
        sleep 2

        verify() {
            systemctl is-active --quiet "$SVC" || return 1
            ss -tln | awk -v p=":$APIPORT\$" '$4 ~ p {f=1} END{exit !f}' || return 1
            pgrep -f "$XRAY -c" >/dev/null 2>&1 || return 1
            "$XRAY" api statsquery --server="127.0.0.1:$APIPORT" -pattern "" >/dev/null 2>&1 || return 1
            return 0
        }

        if verify; then
            info "服务自检通过：服务 active / API 监听 127.0.0.1:$APIPORT / statsquery 可用"
        else
            warn "自检失败，自动回滚"
            cat "$BAK" > "$CONFIG"
            systemctl restart "$SVC"; sleep 2
            smd5=$(md5sum "$CONFIG" | awk '{print $1}')
            die "已回滚到 $ORIG_MD5（当前 $smd5），服务状态: $(systemctl is-active "$SVC")；排查: journalctl -u $SVC -n 30"
        fi
    fi
fi

# ---------------------------------------------------------------- 真实流量自测
if [ "$SELFTEST" = yes ]; then
    if ! command -v curl >/dev/null 2>&1; then
        warn "缺少 curl，跳过真实流量自测"
    else
        SOCKPORT=$((20000 + RANDOM % 20000))
        TMPC=$(mktemp -d /tmp/xray-selftest.XXXXXX)
        if python3 - "$WORKDIR" "$SOCKPORT" > "$TMPC/client.json" <<'PY'
import json, os, re, subprocess, sys
wd, sockport = sys.argv[1], int(sys.argv[2])
xray = os.path.join(wd, "xray")
cfg = json.load(open(os.path.join(wd, "config.json"), encoding="utf-8"))
uuid = open(os.path.join(wd, "uuid.txt")).read().strip()
ptf = os.path.join(wd, "protocol.txt")
proto = open(ptf).read().strip() if os.path.exists(ptf) else ""
main = next(x for x in cfg["inbounds"]
            if x.get("protocol") == "vless" and x.get("tag") != "api")
ss = main.get("streamSettings") or {}
if not proto:
    proto = "reality" if ss.get("security") == "reality" else "encryption"

if proto == "reality":
    xt = open(os.path.join(wd, "xrayinit")).read()
    m = re.search(r"tcp://([^\s]+)", xt)
    if not m: sys.exit("无法从 xrayinit 解析 sni-filter 监听地址")
    hp = m.group(1)
    if hp.startswith("["):
        host, port = hp[1:].split("]:")[0], int(hp.rsplit("]:", 1)[1])
    else:
        host, port = hp.rsplit(":", 1)[0], int(hp.rsplit(":", 1)[1])
    if host in ("0.0.0.0", "::"): host = "127.0.0.1"
    rs = ss["realitySettings"]
    r = subprocess.run([xray, "x25519", "-i", rs["privateKey"]], capture_output=True, text=True)
    # 标签兼容：Xray 26.3.27 输出为 "Password (PublicKey): xxx"（旧版为 "Password: xxx"）
    pbk = ""
    for line in r.stdout.splitlines():
        m = re.match(r"^Password[^:]*:\s*(\S+)", line)
        if m:
            pbk = m.group(1); break
    if not pbk: sys.exit("无法由 privateKey 派生 publicKey（xray 输出格式可能已变更）")
    users = [{"id": uuid, "encryption": "none", "flow": "xtls-rprx-vision", "level": 0}]
    stream = {"network": "tcp", "security": "reality",
              "realitySettings": {"serverName": rs["serverNames"][0], "fingerprint": "chrome",
                                  "publicKey": pbk, "shortId": (rs.get("shortIds") or [""])[0]}}
else:
    host = main.get("listen") or "127.0.0.1"
    if host in ("0.0.0.0", "::", "[::]"): host = "127.0.0.1"
    port = int(main.get("port") or 443)
    enc = open(os.path.join(wd, "encryption_key.txt")).read().strip()
    users = [{"id": uuid, "encryption": enc, "flow": "xtls-rprx-vision", "level": 0}]
    stream = {"network": "tcp", "security": "none"}

print(json.dumps({
    "log": {"loglevel": "warning"},
    "inbounds": [{"tag": "selftest-socks", "listen": "127.0.0.1", "port": sockport,
                  "protocol": "socks", "settings": {"auth": "noauth", "udp": False}}],
    "outbounds": [{"tag": "selftest-out", "protocol": "vless",
                   "settings": {"vnext": [{"address": host, "port": port, "users": users}]},
                   "streamSettings": stream}]
}, indent=2, ensure_ascii=False))
PY
        then
            setsid "$XRAY" run -c "$TMPC/client.json" > "$TMPC/client.log" 2>&1 &
            CPID=$!
            sleep 2
            CODE=$(curl -s -x "socks5h://127.0.0.1:$SOCKPORT" -o /dev/null -w '%{http_code}' \
                   --max-time 20 https://www.gstatic.com/generate_204 2>/dev/null || true)
            DL=$("$XRAY" api statsquery --server="127.0.0.1:$APIPORT" \
                 -pattern "user>>>$EMAIL>>>traffic>>>downlink" 2>/dev/null \
                 | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["stat"]
    print(d[0].get("value",0) if d else 0)
except Exception:
    print(0)' || echo 0)
            kill "$CPID" 2>/dev/null || true
            wait "$CPID" 2>/dev/null || true
            rm -rf "$TMPC"
            # 自测流量清零，避免污染统计基线
            "$XRAY" api statsquery --server="127.0.0.1:$APIPORT" -pattern "" -reset=true >/dev/null 2>&1 || true
            if [ "$CODE" = "204" ] && [ "${DL:-0}" -gt 0 ]; then
                info "真实流量自测通过：HTTP 204，user>>>$EMAIL 下行计数 ${DL} B，统计已清零"
            else
                warn "真实流量自测未通过（HTTP=${CODE:-无}，下行计数=${DL:-0}）——服务本身已生效，请检查客户端侧或稍后复测"
            fi
        else
            warn "无法生成自测客户端（可能为非标准形态），跳过真实流量自测"
            rm -rf "$TMPC"
        fi
    fi
fi

echo ""
info "完成。统计已就绪（重启 $SVC 后计数归零）"
echo "    查询全部: $XRAY api statsquery --server=127.0.0.1:$APIPORT -pattern ''"
echo "    按客户端: $XRAY api statsquery --server=127.0.0.1:$APIPORT -pattern 'user>>>$EMAIL'"
echo "    读后清零: $XRAY api statsquery --server=127.0.0.1:$APIPORT -pattern '' -reset=true"
echo "    备份文件: $WORKDIR/config.json.bak-stats-*（回滚: $0 --rollback）"
