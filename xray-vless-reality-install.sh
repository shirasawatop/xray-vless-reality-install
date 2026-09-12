#!/bin/bash
# ============================================================================
# Xray VLESS 二合一部署脚本：REALITY / VLESS Encryption        v1.0.3 (2026-09-12)
# ----------------------------------------------------------------------------
# 功能：交互式部署 Xray 服务端，二选一：
#   ① REALITY（+ sni-filter：443 由 sni-filter 监听，xray 走 unix socket）
#   ② VLESS Encryption（xray 本体监听 443）
#   部署后生成管理命令：xray.chaguuid / start / stop / restart / status / log / help / delxray
#
# 权限模型（有意为之，勿随意放宽）：
#   - 服务以 xrayuser 运行；二进制与入口脚本归 root（root:root 755）
#   - config.json → root:xrayuser 640     uuid.txt → root:root 600
#   - chaguuid 内联客户端参数 → root:root 700
#   - 目录 /var/xray 归 root（755）；仅 xray.pid / sni-filter.pid / statusfilter
#     与 socket/ 归 xrayuser（运行期写入；目录收口见阶段 20）
#
# 注意：在已有部署上重跑本脚本会重新生成密钥与 UUID（现有客户端立即失效）；
#       脚本已内置 root / 依赖 / 重复安装三项前置检查与二次确认。
# 谱系：交互逻辑基于上游 v20260710（r7），并叠加 2026-09 的加固修复。
# 许可：MIT License — Copyright (c) 2026 shirasawatop（全文见仓库 LICENSE）
# ============================================================================
set -e

readonly C_RED='\e[31m'; readonly C_GREEN='\e[32m'
readonly C_YELLOW='\e[33m'; readonly C_CYAN='\e[36m'; readonly C_NC='\e[0m'

# ============================================================
# 前置检查（root / 依赖 / 重复安装，位于阶段 0 之前）
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${C_RED}请以 root 身份运行本脚本（需写 /etc/systemd/system、创建系统用户、绑定 443）${C_NC}"
    exit 1
fi

workdir=/var/xray

missing_deps=()
for cmd in wget openssl unzip; do
    command -v "$cmd" &>/dev/null || missing_deps+=("$cmd")
done
if [ ${#missing_deps[@]} -gt 0 ]; then
    echo -e "${C_YELLOW}缺少依赖: ${missing_deps[*]}${C_NC}"
    echo "请先安装后重试： apt-get update && apt-get install -y ${missing_deps[*]}"
    exit 1
fi

# 重复安装保护：本脚本会重新生成密钥与 UUID 并覆盖 config.json
if [ -f "$workdir/config.json" ]; then
    echo -e "${C_YELLOW}检测到 $workdir/config.json 已存在（疑似已安装）。${C_NC}"
    echo -e "${C_YELLOW}继续执行将重新生成密钥与 UUID 并覆盖 config.json，现有客户端会立即失效。${C_NC}"
    read -rp "确认继续？输入 yes 继续，其它任意输入退出: " rerun_confirm || rerun_confirm=""
    [ "$rerun_confirm" = "yes" ] || { echo "已取消"; exit 0; }
fi

echo -e "${C_GREEN}欢迎使用 REALITY / VLESS Encryption 二合一脚本 v1.0.3${C_NC}"
echo ""
echo "         _      _   __        _                   _ "
echo "   ___  | |  __| | / _| _ __ (_)  ___  _ __    __| |"
echo "  / _ \\ | | / _\` || |_ | '__|| | / _ \\| '_ \\  / _\` |"
echo " | (_) || || (_| ||  _|| |   | ||  __/| | | || (_| |"
echo "  \\___/ |_| \\__,_||_|  |_|   |_| \\___||_| |_| \\__,_|"
echo ""
sleep 1

# ============================================================
# 阶段 0：协议选择
# ============================================================
echo -e "${C_YELLOW}╔══════════════════════════════════════════════════╗${C_NC}"
echo -e "${C_YELLOW}║          ⚠️  重要提示 ⚠️                        ║${C_NC}"
echo -e "${C_YELLOW}║                                                ║${C_NC}"
echo -e "${C_YELLOW}║  REALITY 和 VLESS Encryption 是两种不同的        ║${C_NC}"
echo -e "${C_YELLOW}║  传输安全方案，不能在同一条 inbound 中共存！      ║${C_NC}"
echo -e "${C_YELLOW}║                                                ║${C_NC}"
echo -e "${C_YELLOW}║  • REALITY: 伪装成访问知名网站，抗主动探测最强   ║${C_NC}"
echo -e "${C_YELLOW}║  • Encryption: 自带加密+抗量子，适合CDN/中转    ║${C_NC}"
echo -e "${C_YELLOW}╚══════════════════════════════════════════════════╝${C_NC}"
echo ""

if command -v whiptail &>/dev/null; then
    protocol_choice=$(whiptail --title "协议选择" --menu "请选择传输安全协议（两者不可共存）" 18 60 2 \
        "reality" "REALITY - 伪装网站，抗主动探测" \
        "encryption" "VLESS Encryption - 自带加密，抗量子" 3>&1 1>&2 2>&3)
else
    echo "请选择协议:"
    echo "  1) REALITY - 伪装网站，抗主动探测"
    echo "  2) VLESS Encryption - 自带加密，抗量子"
    read -rp "请输入 (1/2): " c
    case "$c" in 1) protocol_choice="reality";; 2) protocol_choice="encryption";; *) echo "无效选择"; exit 1;; esac
fi

if [ -z "$protocol_choice" ]; then
    echo -e "${C_RED}未选择协议，退出安装${C_NC}"
    exit 1
fi
protocol="$protocol_choice"

echo -e "${C_GREEN}已选择: $([ "$protocol" = "reality" ] && echo "REALITY 协议" || echo "VLESS Encryption 协议")${C_GREEN}"
echo ""

# ============================================================
# 阶段 1：自动检测系统IP地址
# ============================================================
detect_ips() {
    echo -e "${C_GREEN}正在检测系统网络配置...${C_NC}"
    
    ipv4_addresses=()
    ipv4_interfaces=()
    interfaces=$(ip -o link show | awk -F': ' '{print $2}')
    
    for iface in $interfaces; do
        [[ "$iface" == "lo" || "$iface" == docker* || "$iface" == br-* || "$iface" == veth* ]] && continue
        ipv4_list=$(ip -4 addr show $iface 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        for ipv4 in $ipv4_list; do
            ipv4_addresses+=("$ipv4")
            ipv4_interfaces+=("$iface: $ipv4")
        done
    done
    
    ipv6_addresses=()
    ipv6_interfaces=()
    for iface in $interfaces; do
        [[ "$iface" == "lo" || "$iface" == docker* || "$iface" == br-* || "$iface" == veth* ]] && continue
        ipv6_list=$(ip -6 addr show $iface 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80:' | grep -v '^::1')
        for ipv6 in $ipv6_list; do
            ipv6_addresses+=("$ipv6")
            ipv6_interfaces+=("$iface: $ipv6")
        done
    done
    
    echo -e "${C_GREEN}检测到的IPv4地址:${C_NC}"
    if [ ${#ipv4_interfaces[@]} -eq 0 ]; then
        echo "  未检测到IPv4地址"
    else
        for i in "${!ipv4_interfaces[@]}"; do
            echo "  [$((i+1))] ${ipv4_interfaces[$i]}"
        done
    fi
    
    echo -e "${C_GREEN}检测到的IPv6地址:${C_NC}"
    if [ ${#ipv6_interfaces[@]} -eq 0 ]; then
        echo "  未检测到IPv6地址"
    else
        for i in "${!ipv6_interfaces[@]}"; do
            echo "  [$((i+1))] ${ipv6_interfaces[$i]}"
        done
    fi
    echo ""
}

detect_ips

# ============================================================
# 阶段 2：基础变量
# ============================================================
ipaddr=""; portx=""
fingerprint="chrome"
ipv4_outbound=""; ipv6_outbound=""; use_ipv6_priority="yes"
ddns_enabled="no"; ddns_type=""; ddns_target_ip=""; ddns_strategy=""
mtu_enabled="no"; mtu_interface="eth0"; mtu_value="1390"

# REALITY 特有变量
domain_s="www.fastly.com"

# VLESS Encryption 特有变量
vless_key_mode="mlkem768"
vless_appearance="random"
vless_rtt="0rtt"
vless_ticket="600s"

echo ""

# ============================================================
# 阶段 3：出口IP配置
# ============================================================
echo -e "${C_GREEN}配置出口IP地址${C_NC}"
if command -v whiptail &>/dev/null; then
    ipv6_priority=$(whiptail --title "IPv6优先" --menu "是否优先使用IPv6出口？" 15 50 4 \
        "yes" "是，IPv6优先" "no" "否，IPv4优先" 3>&1 1>&2 2>&3)
else
    read -rp "是否优先使用 IPv6 出口？(y/n, 默认 y): " ans
    [[ "$ans" =~ ^[Nn] ]] && ipv6_priority="no" || ipv6_priority="yes"
fi
[[ "$ipv6_priority" == "yes" ]] && use_ipv6_priority="yes" || use_ipv6_priority="no"
echo "已选择$([ "$use_ipv6_priority" = "yes" ] && echo "IPv6优先" || echo "IPv4优先")出口"

# IPv4出口
if [ ${#ipv4_addresses[@]} -gt 0 ]; then
    echo -e "${C_GREEN}请选择IPv4出口地址:${C_NC}"
    select opt in "使用检测到的地址" "手动输入地址" "不使用IPv4出口"; do
        case $opt in
            "使用检测到的地址")
                if [ ${#ipv4_addresses[@]} -eq 1 ]; then ipv4_outbound="${ipv4_addresses[0]}"
                else select addr in "${ipv4_addresses[@]}"; do ipv4_outbound="$addr"; break; done; fi
                break;;
            "手动输入地址") read -rp "地址: " ipv4_outbound; break;;
            "不使用IPv4出口") break;;
        esac
    done
else
    read -rp "未检测到IPv4，手动输入（留空取消）: " ipv4_outbound
fi

# IPv6出口
if [ ${#ipv6_addresses[@]} -gt 0 ]; then
    echo -e "${C_GREEN}请选择IPv6出口地址:${C_NC}"
    select opt in "使用检测到的地址" "手动输入地址" "不使用IPv6出口"; do
        case $opt in
            "使用检测到的地址")
                if [ ${#ipv6_addresses[@]} -eq 1 ]; then ipv6_outbound="${ipv6_addresses[0]}"
                else select addr in "${ipv6_addresses[@]}"; do ipv6_outbound="$addr"; break; done; fi
                break;;
            "手动输入地址") read -rp "地址: " ipv6_outbound; break;;
            "不使用IPv6出口") break;;
        esac
    done
else
    read -rp "未检测到IPv6，手动输入（留空取消）: " ipv6_outbound
fi

# ============================================================
# 阶段 4：DDNS 自动更换出口 IP
# ============================================================
if command -v whiptail &>/dev/null; then
    if whiptail --yesno "是否开启当出口IP丢失后自动更换功能？" 10 50; then
        choice=$(whiptail --menu "选择监控类型" 15 50 2 "ipv6" "IPv6出口" "ipv4" "IPv4出口" 3>&1 1>&2 2>&3)
        case $choice in
            ipv6)
                if [ -z "$ipv6_outbound" ]; then echo "未配置IPv6出口，忽略"
                else
                    ddns_type="ipv6"; ddns_target_ip="$ipv6_outbound"
                    prefix12="$(echo $ddns_target_ip | cut -d: -f1):"
                    prefix28="$(echo $ddns_target_ip | cut -d: -f1-2):"
                    prefix48="$(echo $ddns_target_ip | cut -d: -f1-3):"
                    strat=$(whiptail --menu "匹配策略" 15 50 4 \
                        "match12" "$prefix12 开头" "match28" "$prefix28 开头" \
                        "match48" "$prefix48 开头" "any" "任意不同IPv6" 3>&1 1>&2 2>&3)
                    ddns_strategy="$strat"; ddns_enabled="yes"
                fi ;;
            ipv4)
                if [ -z "$ipv4_outbound" ]; then echo "未配置IPv4出口，忽略"
                else
                    ddns_type="ipv4"; ddns_target_ip="$ipv4_outbound"
                    IFS='.' read -r a b c d <<< "$ddns_target_ip"
                    strat=$(whiptail --menu "匹配策略" 15 50 4 \
                        "match8" "$a. 开头" "match16" "$a.$b. 开头" \
                        "match24" "$a.$b.$c. 开头" "any" "任意不同IPv4" 3>&1 1>&2 2>&3)
                    ddns_strategy="$strat"; ddns_enabled="yes"
                fi ;;
        esac
    fi
else
    read -rp "开启 DDNS 自动更换 IP？(y/n): " ans
    if [[ "$ans" =~ ^[Yy] ]]; then
        read -rp "监控类型 (ipv6/ipv4): " ddns_type
        if [ "$ddns_type" = "ipv6" ] && [ -n "$ipv6_outbound" ]; then
            ddns_target_ip="$ipv6_outbound"; ddns_enabled="yes"; ddns_strategy="any"
        elif [ "$ddns_type" = "ipv4" ] && [ -n "$ipv4_outbound" ]; then
            ddns_target_ip="$ipv4_outbound"; ddns_enabled="yes"; ddns_strategy="any"
        fi
    fi
fi

# ============================================================
# 阶段 5：MTU 自动调整
# ============================================================
if command -v whiptail &>/dev/null; then
    if whiptail --yesno "是否开启 MTU 自动调整？\n（用于修复部分隧道环境下 Reality/Encryption 连接失败，推荐值 1390）" 12 60; then
        mtu_enabled="yes"
        read -rp "网络接口名（默认 eth0）: " input_if
        [ -n "$input_if" ] && mtu_interface="$input_if"
        read -rp "MTU 值（默认 1390）: " input_mtu
        [ -n "$input_mtu" ] && mtu_value="$input_mtu"
        echo "MTU 将设置为: $mtu_interface mtu $mtu_value"
    fi
else
    read -rp "开启 MTU 调整？(y/n): " ans
    if [[ "$ans" =~ ^[Yy] ]]; then
        mtu_enabled="yes"
        read -rp "网络接口（默认 eth0）: " input_if; [ -n "$input_if" ] && mtu_interface="$input_if"
        read -rp "MTU 值（默认 1390）: " input_mtu; [ -n "$input_mtu" ] && mtu_value="$input_mtu"
    fi
fi

echo ""

# ============================================================
# 阶段 6：协议专属配置
# ============================================================
echo -e "${C_GREEN}配置 $([ "$protocol" = "reality" ] && echo "REALITY" || echo "VLESS Encryption") 参数${C_NC}"

read -rp "监听IP (默认0.0.0.0): " ipaddr; [ -z "$ipaddr" ] && ipaddr="0.0.0.0"
read -rp "监听端口 (默认443): " portx; [ -z "$portx" ] && portx="443"

if [ "$protocol" = "reality" ]; then
    read -rp "伪装域名 (默认www.fastly.com): " domain_s; [ -z "$domain_s" ] && domain_s="www.fastly.com"

    if command -v whiptail &>/dev/null; then
        fp_choice=$(whiptail --title "浏览器指纹" --menu "选择指纹" 15 50 5 \
            "chrome" "Chrome" "firefox" "Firefox" "safari" "Safari" "ios" "iOS" "edge" "Edge" 3>&1 1>&2 2>&3)
        [ -n "$fp_choice" ] && fingerprint="$fp_choice"
    else
        echo "选择指纹: 1)chrome 2)firefox 3)safari 4)ios 5)edge"
        read -rp "选择 (默认 chrome): " c
        case "$c" in 2) fingerprint="firefox";; 3) fingerprint="safari";; 4) fingerprint="ios";; 5) fingerprint="edge";; esac
    fi

    echo "配置: $ipaddr:$portx?sni=$domain_s&fp=$fingerprint"
else
    echo ""
    echo -e "${C_YELLOW}╔══════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_YELLOW}║     VLESS Encryption 配置选项                   ║${C_NC}"
    echo -e "${C_YELLOW}║  密钥模式: ① mlkem768 ② x25519                  ║${C_NC}"
    echo -e "${C_YELLOW}║  外观模式: ① native ② xorpub ③ random           ║${C_NC}"
    echo -e "${C_YELLOW}║  RTT模式:  ① 0rtt  ② 1rtt                       ║${C_NC}"
    echo -e "${C_YELLOW}╚══════════════════════════════════════════════════╝${C_NC}"
    echo ""

    echo -e "${C_GREEN}请选择密钥模式:${C_NC}"
    select km in "mlkem768（抗量子，推荐）" "x25519（传统）"; do
        case $km in
            "mlkem768（抗量子，推荐）") vless_key_mode="mlkem768"; break;;
            "x25519（传统）") vless_key_mode="x25519"; break;;
        esac
    done

    echo -e "${C_GREEN}请选择外观模式:${C_NC}"
    select ap in "native（原生，性能最佳）" "xorpub（XOR公钥，隐藏特征）" "random（全随机，最隐蔽）"; do
        case $ap in
            "native（原生，性能最佳）") vless_appearance="native"; break;;
            "xorpub（XOR公钥，隐藏特征）") vless_appearance="xorpub"; break;;
            "random（全随机，最隐蔽）") vless_appearance="random"; break;;
        esac
    done

    echo -e "${C_GREEN}请选择RTT模式:${C_NC}"
    select rtt in "0rtt（零往返，更快）" "1rtt（每次握手，更安全）"; do
        case $rtt in
            "0rtt（零往返，更快）") vless_rtt="0rtt"; break;;
            "1rtt（每次握手，更安全）") vless_rtt="1rtt"; break;;
        esac
    done

    read -rp "Ticket 时长秒数（默认600，仅0rtt模式生效）: " input_ticket
    [ -n "$input_ticket" ] && vless_ticket="${input_ticket}s" || vless_ticket="600s"

    echo "配置: $ipaddr:$portx | key=$vless_key_mode | appearance=$vless_appearance | rtt=$vless_rtt"
fi

# ============================================================
# 阶段 7：检查和依赖
# ============================================================
ping -c 2 8.8.8.8 &>/dev/null || ping -c 2 1.1.1.1 &>/dev/null || { echo "无网络连接"; exit 1; }

# ============================================================
# 阶段 8：下载和安装 Xray（workdir 已在阶段 0 定义）
# ============================================================
mkdir -p $workdir
cd $workdir
arch=$(uname -m)
case $arch in
    x86_64) url="https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip";;
    i386|i686) url="https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-32.zip";;
    aarch64) url="https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-arm64-v8a.zip";;
    *) echo "未知架构: $arch"; exit 1;;
esac
wget -q $url -O xray.zip
unzip -o xray.zip && rm xray.zip
chmod 755 xray
id_s=$(./xray uuid)
mkdir -p socket

# ============================================================
# 阶段 9：协议专属密钥生成
# ============================================================
if [ "$protocol" = "reality" ]; then
    xray_x25519=$(./xray x25519)
    shortIds=$(openssl rand -hex 6)
    private_old=$(echo "$xray_x25519" | grep "PrivateKey:" | cut -d' ' -f2-)
    public_old=$(echo "$xray_x25519" | grep "Password:" | cut -d' ' -f2-)
    echo "REALITY 密钥已生成"
else
    if [ "$vless_key_mode" = "mlkem768" ]; then
        enc_output=$(./xray mlkem768)
        enc_server_key=$(echo "$enc_output" | grep "Seed:" | head -1 | awk '{print $2}')
        enc_client_key=$(echo "$enc_output" | grep "Client:" | head -1 | awk '{print $2}')
    else
        x25519_output=$(./xray x25519)
        enc_server_key=$(echo "$x25519_output" | grep "PrivateKey:" | cut -d' ' -f2-)
        enc_client_key=$(echo "$x25519_output" | grep "Password:" | cut -d' ' -f2-)
    fi
    decryption_str="mlkem768x25519plus.${vless_appearance}.${vless_ticket}.${enc_server_key}"
    encryption_str="mlkem768x25519plus.${vless_appearance}.${vless_rtt}.${enc_client_key}"
    echo "VLESS Encryption 密钥已生成"
fi

# ============================================================
# 阶段 10：出站与路由函数
# ============================================================
generate_outbounds() {
    local type="$1" sip="$2" sport="$3" suser="$4" spass="$5"
    local json="["
    if [[ "$type" == "socks" ]]; then
        [[ -n "$ipv6_outbound" ]] && json+='{"tag":"direct-ipv6","protocol":"socks","settings":{"servers":[{"address":"'"$sip"'","port":'"$sport"',"users":[{"user":"'"$suser"'","pass":"'"$spass"'","level":0}]}]},"sendThrough":"'"$ipv6_outbound"'"},'
        [[ -n "$ipv4_outbound" ]] && json+='{"tag":"direct-ipv4","protocol":"socks","settings":{"servers":[{"address":"'"$sip"'","port":'"$sport"',"users":[{"user":"'"$suser"'","pass":"'"$spass"'","level":0}]}]},"sendThrough":"'"$ipv4_outbound"'"},'
    else
        [[ -n "$ipv6_outbound" ]] && json+='{"protocol":"freedom","tag":"direct-ipv6","settings":{"domainStrategy":"UseIPv6"},"sendThrough":"'"$ipv6_outbound"'"},'
        [[ -n "$ipv4_outbound" ]] && json+='{"protocol":"freedom","tag":"direct-ipv4","settings":{"domainStrategy":"UseIPv4"},"sendThrough":"'"$ipv4_outbound"'"},'
    fi
    json="${json%,}"; json+="]"
    echo "$json"
}

generate_routing() {
    local routing=""
    if [[ -n "$ipv6_outbound" && -n "$ipv4_outbound" ]]; then
        if [[ "$use_ipv6_priority" == "yes" ]]; then
            routing='
    "routing": {
        "domainStrategy": "IPOnDemand",
        "rules": [
            {"type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"]},
            {"type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"]}
        ]
    }'
        else
            routing='
    "routing": {
        "domainStrategy": "IPOnDemand",
        "rules": [
            {"type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"]},
            {"type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"]}
        ]
    }'
        fi
    elif [[ -n "$ipv6_outbound" ]]; then
        routing='
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [{"type": "field", "outboundTag": "direct-ipv6", "network": "tcp,udp"}]
    }'
    elif [[ -n "$ipv4_outbound" ]]; then
        routing='
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [{"type": "field", "outboundTag": "direct-ipv4", "network": "tcp,udp"}]
    }'
    fi
    echo "$routing"
}

# 落地方式
echo "选择落地方式:"
select outlougt in "直接落地" "socks5落地"; do
    case $outlougt in
        "直接落地") outlougt="direct"; break;;
        "socks5落地") outlougt="socks"; break;;
    esac
done

if [[ "$outlougt" == "socks" ]]; then
    read -rp "socks5 IP: " sip; read -rp "端口: " sport
    read -rp "用户: " suser; read -rp "密码: " spass
    outbounds_config=$(generate_outbounds "socks" "$sip" "$sport" "$suser" "$spass")
else
    outbounds_config=$(generate_outbounds "direct")
fi
routing_config=$(generate_routing)

# ============================================================
# 阶段 11：配置生成（协议分支）
# ============================================================
if [ "$protocol" = "reality" ]; then
    cat > config.json <<EOF
{"log": {"loglevel": "warning"},"inbounds": [{
    "listen": "${workdir}/socket/xray.friend,0600",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "$id_s","flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "dest": "$domain_s:443",
            "serverNames": ["$domain_s"],
            "privateKey": "$private_old",
            "shortIds": ["$shortIds"]
        }
    }
}],
"outbounds": $outbounds_config$( [[ -n "$routing_config" ]] && echo "," )$routing_config
}
EOF
else
    cat > config.json <<EOF
{"log": {"loglevel": "warning"},"inbounds": [{
    "port": $portx,
    "listen": "$ipaddr",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "$id_s","flow": "xtls-rprx-vision"}],
        "decryption": "$decryption_str"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "none"
    }
}],
"outbounds": $outbounds_config$( [[ -n "$routing_config" ]] && echo "," )$routing_config
}
EOF
fi

echo "配置已生成"

# ============================================================
# 阶段 12：降权用户
# ============================================================
useradd xrayuser &>/dev/null || true
usermod -s /sbin/nologin xrayuser
chown -R xrayuser:xrayuser $workdir   # 注意：本行会把**目录本身**也交给服务账户；阶段 20 做目录收口
chown root:xrayuser $workdir/config.json && chmod 640 $workdir/config.json
chown root:root $workdir/xray

# ============================================================
# 阶段 13：SNI Filter（仅 REALITY 需要）
# ============================================================
if [ "$protocol" = "reality" ]; then
    # sni-filter 来源：本项目 fork 自 oldfriendme/REALITY-sni-filter（MIT），此处取 fork 的 release 产物
    wget -q https://github.com/shirasawatop/REALITY-sni-filter/releases/download/v0.2/autobuild.zip -O autobuild.zip
    unzip -o autobuild.zip -d . && rm autobuild.zip
    case $arch in
        x86_64) mv sni-filter-amd64 sni-filter;;
        i386|i686) mv sni-filter-i386 sni-filter;;
        aarch64) mv sni-filter-arm64 sni-filter;;
    esac
    # 2026-09-11: 清掉非本机架构的残余二进制
    #   autobuild.zip 里含 3 个架构, unzip -o 全解后只有匹配的那份被 mv 成 sni-filter,
    #   其余两份会长期留在 workdir, 造成"到底在跑哪个二进制"的审计歧义,
    #   并给完整性校验/巡检增加噪音 (约 4MB, 详见手册 §12.6)
    rm -f sni-filter-amd64 sni-filter-i386 sni-filter-arm64
    chmod 755 sni-filter
    chown root:root sni-filter
    # 不再依赖 setcap，权限由 systemd AmbientCapabilities 提供
    echo "SNI Filter 已安装"
else
    echo "VLESS Encryption 模式，跳过 SNI Filter 安装"
fi

# ============================================================
# 阶段 14：生成 xrayinit（启动脚本）
# ============================================================
if [ "$protocol" = "reality" ]; then
    cat > xrayinit << LAUNCHER
#!/bin/bash
setsid $workdir/sni-filter -L=tcp://${ipaddr}:${portx} -F=unix://${workdir}/socket/xray.friend -S=$domain_s &
echo \$! > ${workdir}/sni-filter.pid
setsid $workdir/xray -c $workdir/config.json &
echo \$! > ${workdir}/xray.pid
echo "on" > $workdir/statusfilter
LAUNCHER
else
    cat > xrayinit << LAUNCHER
#!/bin/bash
setsid $workdir/xray -c $workdir/config.json &
echo \$! > ${workdir}/xray.pid
echo "on" > $workdir/statusfilter
LAUNCHER
fi
chmod 755 xrayinit

# ============================================================
# 阶段 15：DDNS 检测脚本
# ============================================================
if [ "$ddns_enabled" == "yes" ]; then
    config_files="config.json"

    cat > ddns_check.sh << 'EOSH'
#!/bin/bash
config_file="DDNS_DIR/ddns.config"
[ ! -f "$config_file" ] && exit 0
read ddns_type target_ip strategy < "$config_file"
if [ "$ddns_type" == "ipv6" ]; then
    if ip -6 addr show | grep -q "$target_ip"; then exit 0; fi
    available_ips=$(ip -6 addr show | grep -oP 'inet6 [0-9a-f:]+' | awk '{print $2}' | grep -v '^fe80:' | grep -v '^::1')
else
    if ip -4 addr show | grep -oP 'inet \d+\.\d+\.\d+\.\d+' | grep -q "$target_ip"; then exit 0; fi
    available_ips=$(ip -4 addr show | grep -oP 'inet \d+\.\d+\.\d+\.\d+')
fi
new_ip=""
if [ "$strategy" == "any" ]; then
    for ip in $available_ips; do
        [ "$ip" != "$target_ip" ] && { new_ip="$ip"; break; }
    done
else
    case "$strategy" in
        match12) prefix=$(echo "$target_ip" | cut -d: -f1):;;
        match28) prefix=$(echo "$target_ip" | cut -d: -f1-2):;;
        match48) prefix=$(echo "$target_ip" | cut -d: -f1-3):;;
        match8) prefix="$(echo $target_ip | cut -d. -f1).";;
        match16) prefix="$(echo $target_ip | cut -d. -f1-2).";;
        match24) prefix="$(echo $target_ip | cut -d. -f1-3).";;
    esac
    for ip in $available_ips; do
        if [[ "$ip" == "$prefix"* ]] && [ "$ip" != "$target_ip" ]; then new_ip="$ip"; break; fi
    done
fi
if [ -n "$new_ip" ]; then
    for cfg in CONFIG_FILES; do
        sed -i "s/$target_ip/$new_ip/g" DDNS_DIR/$cfg
    done
    echo "$ddns_type $new_ip $strategy" > "$config_file"
    kill $(cat DDNS_DIR/xray.pid) 2>/dev/null; sleep 1
    if [ -f DDNS_DIR/sni-filter.pid ]; then
        kill $(cat DDNS_DIR/sni-filter.pid) 2>/dev/null
        setsid DDNS_DIR/sni-filter -L=tcp://LISTEN_IP:LISTEN_PORT -F=unix://DDNS_DIR/socket/xray.friend -S=SNI_DOMAIN &
        echo $! > DDNS_DIR/sni-filter.pid
    fi
    setsid DDNS_DIR/xray -c DDNS_DIR/config.json &
    echo $! > DDNS_DIR/xray.pid
fi
EOSH
    sed -i "s|CONFIG_FILES|$config_files|g; s|LISTEN_IP|$ipaddr|g; s|LISTEN_PORT|$portx|g; s|SNI_DOMAIN|$domain_s|g" ddns_check.sh
    sed -i "s|DDNS_DIR|$workdir|g" ddns_check.sh
    chmod +x ddns_check.sh
    echo "$ddns_type $ddns_target_ip $ddns_strategy" > ddns.config
    chown xrayuser:xrayuser ddns.config && chmod 600 ddns.config

    cat >> xrayinit << EOF
while true; do
    sleep 60
    $workdir/ddns_check.sh
done
EOF
else
    cat >> xrayinit << 'EOF'
while true; do sleep 3600; done
EOF
fi

# ============================================================
# 阶段 16：Systemd 服务（★ 核心修复：AmbientCapabilities）
# ============================================================
mtu_line=""
[ "$mtu_enabled" = "yes" ] && mtu_line="ExecStartPre=+/usr/sbin/ip link set dev $mtu_interface mtu $mtu_value"

proto_label="$([ "$protocol" = "reality" ] && echo "REALITY" || echo "VLESS Encryption")"

cat > /etc/systemd/system/xray_service.service << EOF
[Unit]
Description=Xray Service ($proto_label)
After=network.target

[Service]
Type=simple
${mtu_line}
ExecStart=/usr/bin/sh $workdir/xrayinit
User=xrayuser
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ============================================================
# 阶段 17：生成管理脚本
# ============================================================
echo -n "$id_s" > uuid.txt
chmod 600 uuid.txt
realip4=$(wget -q4 -O- https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep ip= | cut -d= -f2 || echo "")
realip6=$(wget -q6 -O- https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep ip= | cut -d= -f2 || echo "")

echo "$protocol" > protocol.txt
if [ "$protocol" = "encryption" ]; then
    echo "$encryption_str" > encryption_key.txt
    chmod 600 encryption_key.txt
fi

# 构建订阅参数
if [ "$protocol" = "reality" ]; then
    sub_gen="encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s"
else
    enc_for_link=$(cat $workdir/encryption_key.txt 2>/dev/null)
    sub_gen="encryption=${enc_for_link}&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none"
fi

# chaguuid
cat > chaguuid << EOF
#!/bin/bash
newuuid=\$($workdir/xray uuid)
olduuid=\$(cat $workdir/uuid.txt)
case "\$olduuid" in ""|*[!0-9a-fA-F-]*) echo "uuid.txt 内容异常，拒绝执行"; exit 1;;
esac
[ "\${#olduuid}" -eq 36 ] || { echo "uuid.txt 长度异常，拒绝执行"; exit 1; }
grep -qF -- "\$olduuid" $workdir/config.json || { echo "uuid.txt 与 config.json 不匹配，拒绝执行"; exit 1; }
esc_old=\$(printf '%s' "\$olduuid" | sed 's/[^0-9a-zA-Z]/\\\\&/g')
sed -i "s/\$esc_old/\$newuuid/g" $workdir/config.json
kill \$(cat $workdir/xray.pid) 2>/dev/null
[ -f $workdir/sni-filter.pid ] && kill \$(cat $workdir/sni-filter.pid) 2>/dev/null
echo -n \$newuuid > $workdir/uuid.txt
chmod 600 $workdir/uuid.txt
systemctl restart xray_service
[ -n "$realip4" ] && echo "IPv4: vless://\$newuuid@$realip4:$portx?${sub_gen}"
[ -n "$realip6" ] && echo "IPv6: vless://\$newuuid@[$realip6]:$portx?${sub_gen}"
EOF

# delxray
cat > delxray << EOF
#!/bin/bash
read -rp "将停止服务并删除 $workdir 与 xrayuser，输入 yes 确认卸载: " del_confirm
[ "\$del_confirm" = "yes" ] || { echo "已取消"; exit 0; }
systemctl stop xray_service; systemctl disable xray_service
kill \$(cat $workdir/xray.pid) 2>/dev/null
[ -f $workdir/sni-filter.pid ] && kill \$(cat $workdir/sni-filter.pid) 2>/dev/null
deluser xrayuser 2>/dev/null
rm -f /usr/bin/xray.* /usr/local/bin/xray.*
rm -rf $workdir
echo "卸载完成"
EOF

# stop / start / restart
for action in stop start restart; do
    cat > xray${action} << EOF
#!/bin/bash
systemctl ${action} xray_service
EOF
done

# help
cat > xrayhelp << EOF
#!/bin/bash
echo "========================================"
echo "  Xray 管理命令 ($proto_label)"
echo "========================================"
echo "xray.chaguuid 更换UUID"
echo "xray.delxray  卸载"
echo "xray.stop     停止"
echo "xray.start    启动"
echo "xray.restart  重启"
echo "xray.status   查看状态"
echo "xray.log      查看日志"
echo "xray.help     帮助"
echo "========================================"
EOF

# status
cat > xraystatus << EOF
#!/bin/bash
systemctl status xray_service --no-pager
echo ""; echo "--- 端口监听 ---"
ss -tlnp 2>/dev/null | grep -E ':(${portx})\b' || echo "未检测到 ${portx} 端口监听"
echo ""; echo "--- 进程 ---"
pgrep -la xray 2>/dev/null || echo "xray 未运行"
pgrep -la sni-filter 2>/dev/null || echo "sni-filter 未运行"
EOF

# log
cat > xraylog << EOF
#!/bin/bash
journalctl -u xray_service -n 50 --no-pager "\$@"
EOF

chmod 755 chaguuid delxray xraystop xraystart xrayrestart xrayhelp xraystatus xraylog 2>/dev/null
chmod 700 chaguuid 2>/dev/null

# 链接到 /usr/bin/ 和 /usr/local/bin/
for cmd in chaguuid delxray xraystop xraystart xrayrestart xrayhelp xraystatus xraylog; do
    linkname="${cmd#xray}"; [ "$linkname" = "$cmd" ] && linkname="$cmd"
    ln -sf $workdir/$cmd /usr/bin/xray.$linkname 2>/dev/null
    ln -sf $workdir/$cmd /usr/local/bin/xray.$linkname 2>/dev/null
done

# ============================================================
# 阶段 18：启动服务
# ============================================================
systemctl daemon-reload
systemctl enable xray_service
systemctl start xray_service

sleep 2

# ============================================================
# 阶段 19：验证
# ============================================================
verify_ok=1
systemctl is-active --quiet xray_service && echo -e "${C_GREEN}[✓] systemd 服务运行中${C_NC}" || { echo -e "${C_RED}[✗] systemd 服务未运行${C_NC}"; verify_ok=0; }
ss -tlnp 2>/dev/null | grep -q ":${portx}\b" && echo -e "${C_GREEN}[✓] 端口 ${portx} 已监听${C_NC}" || { echo -e "${C_RED}[✗] 端口 ${portx} 未监听${C_NC}"; verify_ok=0; }
pgrep -f "$workdir/xray" >/dev/null 2>&1 && echo -e "${C_GREEN}[✓] xray 进程运行中${C_NC}" || { echo -e "${C_RED}[✗] xray 进程未运行${C_NC}"; verify_ok=0; }
if [ "$protocol" = "reality" ]; then
    pgrep -f "$workdir/sni-filter" >/dev/null 2>&1 && echo -e "${C_GREEN}[✓] sni-filter 进程运行中${C_NC}" || { echo -e "${C_RED}[✗] sni-filter 进程未运行${C_NC}"; verify_ok=0; }
fi

if [ $verify_ok -eq 0 ]; then
    echo ""
    echo -e "${C_YELLOW}排查命令:${C_NC}"
    echo "  systemctl status xray_service"
    echo "  journalctl -u xray_service -n 30"
fi

# ============================================================
# 阶段 20：权限收口（目录完整性面）★ 安全关键
# ============================================================
# 背景：
#   阶段 12 的 `chown -R xrayuser:xrayuser $workdir` 会把**目录本身**也交给服务账户。
#   目录可写 ⇒ 即使二进制 / 入口脚本已收归 root:root，服务账户仍可 unlink + 重建它们；
#   而 `chaguuid` 以 root 执行 $workdir/xray ⇒ 形成「先落地、等管理员执行
#   xray.chaguuid」的提权链（项目手册 §12.12 F.2 / §12.15 / §12.16 有实测记录）。
#
# 处置：
#   1) 目录收归 root:root（保留 755：服务账户需 o+rx 穿越，并读取 xrayinit / config.json）
#   2) 运行期由服务账户写入的文件**预建**并留给其持有（必须先建、再收目录）
#   3) socket/ 子目录保持 xrayuser（xray 在其中创建 unix socket 与 lock）
#
# DDNS 例外（二者互斥）：
#   DDNS 路径由 xrayinit（xrayuser 身份）调用 ddns_check.sh，其重写 config.json 依赖
#   **目录写权限**（`sed -i` = 同目录临时文件 + rename）。为不改变既有行为，启用 DDNS 时
#   跳过目录收口并打印警告；如需同时收口，请改用 root 定时器运行 ddns_check.sh
#   （见 README「已知限制」）。
# ============================================================
if [ "$ddns_enabled" = "yes" ]; then
    echo -e "${C_YELLOW}[!] 已启用 DDNS：跳过目录权限收口（DDNS 重写 config.json 需要目录写权限）${C_NC}"
    echo -e "${C_YELLOW}    如需收口，请改用 root 定时器运行 ddns_check.sh，并参阅 README「已知限制」${C_NC}"
else
    touch $workdir/xray.pid $workdir/statusfilter
    chown xrayuser:xrayuser $workdir/xray.pid $workdir/statusfilter
    chmod 644 $workdir/xray.pid $workdir/statusfilter
    if [ -f "$workdir/sni-filter" ]; then
        touch $workdir/sni-filter.pid
        chown xrayuser:xrayuser $workdir/sni-filter.pid
        chmod 644 $workdir/sni-filter.pid
    fi
    chown root:root $workdir
    chmod 755 $workdir
    echo -e "${C_GREEN}[✓] 目录权限收口: $workdir → root:root 755（运行期文件保留 xrayuser）${C_NC}"
fi

# ============================================================
# 阶段 21：输出订阅
# ============================================================
echo ""
echo "========== 安装完成 =========="
echo -e "${C_GREEN}协议: $proto_label${C_NC}"

if [ "$protocol" = "reality" ]; then
    [ -n "$realip4" ] && echo -e "${C_GREEN}IPv4: vless://$id_s@$realip4:$portx?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s#xray_REALITY${C_NC}"
    [ -n "$realip6" ] && echo -e "${C_GREEN}IPv6: vless://$id_s@[$realip6]:$portx?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s#xray_REALITY${C_NC}"
else
    [ -n "$realip4" ] && echo -e "${C_GREEN}IPv4: vless://$id_s@$realip4:$portx?encryption=$encryption_str&flow=xtls-rprx-vision&security=none&type=tcp#xray_Encryption${C_NC}"
    [ -n "$realip6" ] && echo -e "${C_GREEN}IPv6: vless://$id_s@[$realip6]:$portx?encryption=$encryption_str&flow=xtls-rprx-vision&security=none&type=tcp#xray_Encryption${C_NC}"
fi

[ "$mtu_enabled" = "yes" ] && echo "MTU: $mtu_interface mtu $mtu_value"
echo ""
echo "管理命令:"
cat $workdir/xrayhelp
