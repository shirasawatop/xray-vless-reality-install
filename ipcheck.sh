#!/bin/bash
# ============================================================================
# ipcheck.sh —— 本机公网 IP 归属自检（"公网 IP 是否真的在网卡上 / 能否 bind"）
# ----------------------------------------------------------------------------
# 用途：判定本机属于 ①公网 IP 直配网卡  ②1:1 NAT / 弹性公网 IP(EIP)  ③无法探测
#       并给出 xray 相关配置的硬约束建议（sendThrough / 监听 IP）。
#       对应《VPS 安全加固部署手册》§14。
#
# 只读：不修改任何配置、不新增地址、不动防火墙。
# 依赖：iproute2（ip）、wget（探测公网 IP；缺失时退化为仅本地判据）
#
# 用法：
#   ./ipcheck.sh            # 人类可读报告
#   ./ipcheck.sh --json     # 机器可读（便于机队批量采集）
#
# 退出码：0=已判定   1=无法探测公网 IP（仅给出本地事实）   2=用法错误
#
# ⚠️ 刻意不使用 `set -e`：本脚本大量「探测可能失败」的命令（grep/curl/wget），
#    与 set -e 组合正是历史上多次「静默退出」的根因（见 README 变更记录 v1.1.1）。
# ============================================================================
set -o pipefail

JSON=no
case "${1:-}" in
    --json) JSON=yes;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    "") ;;
    *) echo "未知参数: $1（用 --help 查看用法）" >&2; exit 2;;
esac

C_RED='\e[31m'; C_GREEN='\e[32m'; C_YELLOW='\e[33m'; C_CYAN='\e[36m'; C_NC='\e[0m'

# ---------- 1) 本机地址（scope global，排除 lo 与链路本地） ----------
nic4=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2" "$4}' || true)
nic6=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $2" "$4}' || true)
# 纯地址列表（去掉 /前缀）
addr4=$(printf '%s\n' "$nic4" | awk '{print $2}' | cut -d/ -f1 | grep -v '^$' || true)
addr6=$(printf '%s\n' "$nic6" | awk '{print $2}' | cut -d/ -f1 | grep -v '^$' || true)

# ---------- 2) 网关 ----------
gw4=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}' || true)

is_private4() {
    case "$1" in
        10.*|192.168.*|127.*|169.254.*) return 0;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0;;  # CGNAT 100.64/10
        *) return 1;;
    esac
}

# ---------- 3) 探测公网出口 IP ----------
probe4=""; probe6=""
if command -v wget >/dev/null 2>&1; then
    probe4=$(wget -q -4 -O- --timeout=8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1 || true)
    [ -z "$probe4" ] && probe4=$(wget -q -4 -O- --timeout=8 https://api.ipify.org 2>/dev/null | head -1 || true)
    probe6=$(wget -q -6 -O- --timeout=8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1 || true)
    [ -z "$probe6" ] && probe6=$(wget -q -6 -O- --timeout=8 https://ipv6.icanhazip.com 2>/dev/null | head -1 || true)
fi

# ---------- 4) 判据：该地址是否可作源地址（等价于能否 bind） ----------
# 不依赖 python：`ip route get <目标> from <源>` 在源地址非本机时会报
# "RTNETLINK answers: Network is unreachable"（实测 Debian 13 / iproute2）。
can_source4() { ip route get 1.1.1.1 from "$1" >/dev/null 2>&1; }
can_source6() { ip route get 2606:4700:4700::1111 from "$1" >/dev/null 2>&1; }

in_nic() {  # in_nic <地址> <4|6>
    if [ "$2" = "4" ]; then printf '%s\n' "$addr4" | grep -qx "$1"
    else printf '%s\n' "$addr6" | grep -qix "$1"; fi
}

# ---------- 5) 判定 ----------
verdict="unknown"; verdict_text=""; risk=""
if [ -n "$probe4" ]; then
    if in_nic "$probe4" 4; then
        verdict="direct"
        verdict_text="公网 IP 直配网卡：$probe4 出现在本机网卡地址中，可安全用于 sendThrough 与监听 IP"
    elif can_source4 "$probe4"; then
        verdict="direct-like"
        verdict_text="未在网卡列表匹配，但内核接受其作为源地址（可用 bind）：$probe4"
    else
        verdict="eip"
        verdict_text="1:1 NAT / 弹性公网 IP（EIP）：$probe4 不在本机网卡上，内核也不接受其作为源地址"
    fi
fi

# 私网 + 私网网关 ⇒ EIP 的强旁证（即使探测失败也能提示）
gw_hint=""
if [ -n "$gw4" ] && is_private4 "$gw4"; then
    gw_hint="默认网关 $gw4 是私网地址（EIP / 1:1 NAT 的典型特征）"
    [ "$verdict" = "unknown" ] && verdict="eip-by-gw" && verdict_text="探测失败，但按网关类型推断：1:1 NAT / EIP"
elif [ -n "$gw4" ]; then
    gw_hint="默认网关 $gw4 是公网地址（直配网卡的典型特征）"
fi

# ---------- 6) 输出 ----------
if [ "$JSON" = "yes" ]; then
    jq_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
    cat <<EOF
{
  "host": "$(jq_esc "$(hostname)")",
  "nic_ipv4": "$(jq_esc "$(printf '%s ' $addr4)")",
  "nic_ipv6": "$(jq_esc "$(printf '%s ' $addr6)")",
  "gateway_ipv4": "$(jq_esc "$gw4")",
  "public_ipv4": "$(jq_esc "$probe4")",
  "public_ipv6": "$(jq_esc "$probe6")",
  "verdict": "$verdict",
  "verdict_text": "$(jq_esc "$verdict_text")",
  "gateway_hint": "$(jq_esc "$gw_hint")"
}
EOF
    [ "$verdict" = "unknown" ] && exit 1 || exit 0
fi

echo -e "${C_CYAN}=== ipcheck：本机公网 IP 归属自检 ===${C_NC}"
echo "主机      : $(hostname)"
echo "网卡 IPv4 : $(printf '%s ' $addr4)"
echo "网卡 IPv6 : $(printf '%s ' $addr6)"
echo "默认网关  : ${gw4:-（未取到）}"
echo "公网出口  : v4=${probe4:-探测失败}  v6=${probe6:-探测失败/无}"
echo
case "$verdict" in
    direct|direct-like)
        echo -e "${C_GREEN}[判定] $verdict_text${C_NC}"
        echo -e "       建议：sendThrough 可填上面的网卡地址（或留空）；监听 IP 用 0.0.0.0。" ;;
    eip|eip-by-gw)
        echo -e "${C_YELLOW}[判定] $verdict_text${C_NC}"
        echo -e "${C_YELLOW}       ⚠️ 该公网 IP 对外可用、但**不在 guest 网卡上**：${C_NC}"
        echo -e "          · 出站 sendThrough：只能填网卡地址（如 $(printf '%s' "$addr4" | head -1)）或**留空**"
        echo -e "          · 监听 IP：必须用 0.0.0.0（填公网 IP 会 bind 失败）"
        echo -e "          · 违反的典型现象：入口能握手、能连通，但**打不开网页**、客户端**延迟 -1**" ;;
    *)
        echo -e "${C_RED}[判定] 无法探测公网 IP（网络受限或 wget 缺失），仅给出本地事实${C_NC}"
        echo -e "       可手动核对：ip -o addr show | awk '{print \$2,\$3,\$4}'" ;;
esac
[ -n "$gw_hint" ] && echo -e "       旁证：$gw_hint"
echo
echo -e "${C_CYAN}安全提示${C_NC}：本机队实测（手册 §14）—— 云侧**不在边缘挡端口**，"
echo "  未监听端口的 SYN 也会到达虚机（只是回程被丢），故 **nftables 才是唯一防线**；"
echo "  对外探测时「关闭端口」表现为 timeout 而非 refused。"
echo
echo -e "${C_CYAN}手册${C_NC}：VPS安全加固部署手册.md §14（含判据、独享性实测与安全含义）"

[ "$verdict" = "unknown" ] && exit 1
exit 0