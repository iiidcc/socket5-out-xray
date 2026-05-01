#!/bin/bash

# 确认以 root 身份运行
if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 root 权限运行此脚本 (例如: sudo $0)"
  exit 1
fi

# 检查是否启用自动模式 (--auto)
AUTO_MODE=false
[[ "$1" == "--auto" ]] && AUTO_MODE=true

# 全局变量设置
USER="wukunpeng"
PASS="aj8888"
CONFIG_PATH="/usr/local/etc/xray/config.json"
USED_PORTS_FILE="/usr/local/etc/xray/used_ports.txt"
SOCKS5_COUNT=1
COUNTRY=""

# 禁用 IPv6
disable_ipv6() {
  echo "🚫 正在禁用 IPv6..."
  # 临时禁用 IPv6
  sysctl -w net.ipv6.conf.all.disable_ipv6=1
  sysctl -w net.ipv6.conf.default.disable_ipv6=1
  # 永久禁用 IPv6（添加配置）
  grep -q "^net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || cat <<EOF >> /etc/sysctl.conf

# 禁用 IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  # 应用新的 sysctl 配置
  sysctl -p &>/dev/null
}

# 启用 BBR 拥塞控制
enable_bbr() {
  echo "⚙️ 正在启用 BBR 拥塞控制..."
  sysctl -w net.core.default_qdisc=fq
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
}

# 获取当前服务器国家代码（通过 ipinfo.io）
get_current_country() {
  curl -s https://ipinfo.io/country || echo ""
}

# 交互式选择国家代码（支持自动模式静默处理）
detect_country() {
  local detected=$(get_current_country)
  if [[ -n "$detected" ]]; then
    detected=${detected//[^A-Za-z]/}  # 去除可能的换行符等
  fi

  if $AUTO_MODE; then
    COUNTRY="$detected"
    echo "🌍 自动模式：检测到国家代码 $COUNTRY"
    # 若检测结果不在支持列表，则退出
    if [[ ! " US GB DE FR JP MX ES HK TW SG KR AU CA NL RU IN IT CH SE NO PL BR AR TH MY ID VN TR AE ZA NZ PT BE AT FI CL CO PH " =~ " $COUNTRY " ]]; then
      echo "❌ 自动检测到的国家代码 $COUNTRY 不受支持，仅支持 [US GB DE FR JP MX ES HK TW SG KR AU CA NL RU IN IT CH SE NO PL BR AR TH MY ID VN TR AE ZA NZ PT BE AT FI CL CO PH]"
      exit 1
    fi
    return
  fi

  # 手动模式：提示使用检测到的国家或让用户自行输入
  if [[ -n "$detected" ]]; then
    echo "🌍 检测到当前 IP 所在国家代码：$detected"
  else
    echo "⚠️ 无法检测国家代码，请手动选择。"
    detected=""
  fi
  if [[ -n "$detected" && " US GB DE FR JP MX ES HK TW SG KR AU CA NL RU IN IT CH SE NO PL BR AR TH MY ID VN TR AE ZA NZ PT BE AT FI CL CO PH " =~ " $detected " ]]; then
    read -p "👉 是否使用检测到的国家代码? 按回车默认[Y] (Y/n): " use_detected
    if [[ "$use_detected" =~ ^[Nn]$ ]]; then
      detected=""
    fi
  fi
  if [[ -z "$detected" ]]; then
    echo "可选国家代码： [US] [GB] [DE] [FR] [JP] [MX] [ES] [HK] [TW] [SG] [KR] [AU] [CA] [NL] [RU] [IN] [IT] [CH] [SE] [NO] [PL] [BR] [AR] [TH] [MY] [ID] [VN] [TR] [AE] [ZA] [NZ] [PT] [BE] [AT] [FI] [CL] [CO] [PH]"
    read -p "请输入要使用的国家代码: " COUNTRY
  else
    echo "已选择国家代码: $detected"
    COUNTRY="$detected"
  fi

  # 再次验证用户选择的国家代码是否受支持
  if [[ ! " US GB DE FR JP MX ES HK TW SG KR AU CA NL RU IN IT CH SE NO PL BR AR TH MY ID VN TR AE ZA NZ PT BE AT FI CL CO PH " =~ " $COUNTRY " ]]; then
    echo "❌ 不支持的国家代码: $COUNTRY"
    exit 1
  fi
}

# 生成一个未使用的随机端口 (20000-65000)
generate_random_port() {
  local port
  while :; do
    port=$(shuf -i 20000-65000 -n1)
    # 确保该端口未被占用
    if ! lsof -i:"$port" &>/dev/null; then
      echo "$port"
      return
    fi
  done
}

# 安装所需依赖
install_dependencies() {
  echo "📦 正在安装依赖组件..."
  apt-get update -y && apt-get install -y curl unzip qrencode lsof ufw cron
}

# 设置对应国家的时区和 DNS
setup_timezone_and_dns() {
  # 国家代码与时区和DNS服务器映射
  declare -A TIMEZONES=(
    [US]="America/Los_Angeles"
    [GB]="Europe/London"
    [DE]="Europe/Berlin"
    [FR]="Europe/Paris"
    [JP]="Asia/Tokyo"
    [MX]="America/Mexico_City"
    [ES]="Europe/Madrid"
    [HK]="Asia/Hong_Kong"
    [TW]="Asia/Taipei"
    [SG]="Asia/Singapore"
    [KR]="Asia/Seoul"
    [AU]="Australia/Sydney"
    [CA]="America/Toronto"
    [NL]="Europe/Amsterdam"
    [RU]="Europe/Moscow"
    [IN]="Asia/Kolkata"
    [IT]="Europe/Rome"
    [CH]="Europe/Zurich"
    [SE]="Europe/Stockholm"
    [NO]="Europe/Oslo"
    [PL]="Europe/Warsaw"
    [BR]="America/Sao_Paulo"
    [AR]="America/Buenos_Aires"
    [TH]="Asia/Bangkok"
    [MY]="Asia/Kuala_Lumpur"
    [ID]="Asia/Jakarta"
    [VN]="Asia/Ho_Chi_Minh"
    [TR]="Europe/Istanbul"
    [AE]="Asia/Dubai"
    [ZA]="Africa/Johannesburg"
    [NZ]="Pacific/Auckland"
    [PT]="Europe/Lisbon"
    [BE]="Europe/Brussels"
    [AT]="Europe/Vienna"
    [FI]="Europe/Helsinki"
    [CL]="America/Santiago"
    [CO]="America/Bogota"
    [PH]="Asia/Manila"
  )
  declare -A DNS_SERVERS=(
    [US]='["tls://8.8.8.8","tls://8.8.4.4","localhost"]'
    [GB]='["tls://1.1.1.1","tls://1.0.0.1","localhost"]'
    [DE]='["tls://9.9.9.9","tls://149.112.112.112","localhost"]'
    [FR]='["tls://80.67.169.12","tls://80.67.169.40","localhost"]'
    [JP]='["tls://210.130.1.1","tls://210.130.1.2","localhost"]'
    [MX]='["tls://8.8.8.8","tls://8.8.4.4","localhost"]'
    [ES]='["tls://62.36.225.150","tls://8.8.8.8","localhost"]'
    [HK]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [TW]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [SG]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [KR]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [AU]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [CA]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [NL]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [RU]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [IN]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [IT]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [CH]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [SE]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [NO]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [PL]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [BR]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [AR]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [TH]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [MY]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [ID]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [VN]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [TR]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [AE]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [ZA]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [NZ]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [PT]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [BE]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [AT]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [FI]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [CL]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [CO]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
    [PH]='["tls://8.8.8.8","tls://1.1.1.1","localhost"]'
  )
  local timezone="${TIMEZONES[$COUNTRY]}"
  local dns_servers="${DNS_SERVERS[$COUNTRY]}"
  if [[ -z "$timezone" || -z "$dns_servers" ]]; then
    echo "❌ 不支持的国家代码: $COUNTRY"
    exit 1
  fi
  echo "⏱ 设置时区为 $timezone ..."
  timedatectl set-timezone "$timezone"
  DNS_JSON="$dns_servers"
}

# 安装 Xray 核心
install_xray() {
  echo "📥 正在下载并安装 Xray 核心..."
  bash <(curl -L -s https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
  # 修改 Xray 服务运行用户为 root
  sed -i 's/User=nobody/User=root/' /etc/systemd/system/xray.service 2>/dev/null
}

# 配置防火墙 (使用 UFW)
config_firewall() {
  echo "🔒 正在配置防火墙规则..."
  # 重置防火墙并设置默认策略
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  # 开放常用端口
  ufw allow ssh
  ufw allow 53/udp
}

# 生成 Xray 配置文件
generate_xray_config() {
  mkdir -p "$(dirname "$CONFIG_PATH")"
  # 清空旧的已使用端口记录
  : > "$USED_PORTS_FILE"
  # 构建 inbounds 配置段落
  INBOUNDS_JSON='['
  for ((i=0; i<SOCKS5_COUNT; i++)); do
    local PORT
    PORT=$(generate_random_port)
    echo "$PORT" >> "$USED_PORTS_FILE"
    INBOUNDS_JSON+="
      {
        \"listen\": \"0.0.0.0\",
        \"port\": $PORT,
        \"protocol\": \"socks\",
        \"settings\": {
          \"auth\": \"password\",
          \"accounts\": [
            {\"user\": \"$USER\", \"pass\": \"$PASS\"}
          ],
          \"udp\": true
        },
        \"tag\": \"inbound-$PORT\",
        \"sniffing\": {
          \"enabled\": true,
          \"destOverride\": [\"http\", \"tls\"]
        }
      },"
    # 开放 Socks5 端口的防火墙访问
    ufw allow "$PORT/tcp"
    ufw allow "$PORT/udp"
  done
  # 移除最后一个多余的逗号并闭合数组
  INBOUNDS_JSON="${INBOUNDS_JSON%,}]"
  # 生成完整配置 JSON 并写入文件
  cat > "$CONFIG_PATH" <<EOF
{
  "log": {
    "access": "/usr/local/etc/xray/access.log",
    "error": "/usr/local/etc/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": $DNS_JSON
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": $INBOUNDS_JSON,
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ]
}
EOF
  # 启用防火墙使规则生效
  ufw --force enable
}

# 启动并启用 Xray 服务
start_xray() {
  systemctl daemon-reload
  systemctl enable xray
  systemctl restart xray
}

# 输出节点链接及二维码
print_qr_codes() {
  if [[ ! -f "$USED_PORTS_FILE" || ! -s "$USED_PORTS_FILE" ]]; then
    echo "⚠️ 未检测到任何已部署的 Socks5 节点！"
    return
  fi
  local ip
  ip=$(curl -s ifconfig.me || echo "0.0.0.0")
  while IFS= read -r PORT; do
    local link="socks://${USER}:${PASS}@${ip}:${PORT}#SOCKS5-${COUNTRY}-${ip}-${PORT}"
    echo -e "\n🌐 节点链接：$link"
    # 输出二维码 (终端显示)
    echo "$link" | qrencode -t ANSIUTF8
  done < "$USED_PORTS_FILE"
}

# 设置每周定期清理日志
schedule_log_cleanup() {
  # 如果尚未添加日志清理任务，则添加每周一零点清空日志文件的计划任务
  if ! crontab -l 2>/dev/null | grep -q '/usr/local/etc/xray/error.log'; then
    (crontab -l 2>/dev/null; echo "0 0 * * 1 echo '' > /usr/local/etc/xray/access.log && echo '' > /usr/local/etc/xray/error.log") | crontab -
  fi
}

# 卸载 Xray 服务和配置
uninstall_xray() {
  echo "🗑️ 正在卸载 Xray..."
  systemctl stop xray 2>/dev/null
  systemctl disable xray 2>/dev/null
  rm -rf /usr/local/bin/xray /usr/local/etc/xray /etc/systemd/system/xray.service
  echo "✅ Xray 卸载完成"
}

# 执行完整安装流程
full_install() {
  detect_country
  if ! $AUTO_MODE; then
    # 仅手动模式下询问节点数量
    read -p "📦 请输入要创建的节点数量（默认1）: " count
    SOCKS5_COUNT=${count:-1}
  else
    SOCKS5_COUNT=1
    echo "🔢 自动模式：节点数量默认为 $SOCKS5_COUNT"
  fi
  disable_ipv6
  enable_bbr
  install_dependencies
  setup_timezone_and_dns
  install_xray
  config_firewall
  generate_xray_config
  start_xray
  print_qr_codes
  schedule_log_cleanup
  # 创建全局命令别名 aj/AJ
  ln -sf "$(realpath "$0")" /usr/local/bin/aj
  ln -sf "$(realpath "$0")" /usr/local/bin/AJ
  echo -e "\n✅ Socks5 节点部署完成！"
}

# 菜单界面（仅交互模式）
main_menu() {
  echo "+-----------------+"
  echo "| Socks5 部署菜单 |"
  echo "| 1. 安装节点     |"
  echo "| 2. 重新安装     |"
  echo "| 3. 查看节点信息 |"
  echo "| by: TikTok-AJ   |"
  echo "+-----------------+"
  read -p "请输入选项 [1-3] (默认1): " opt
  opt=${opt:-1}
  case "$opt" in
    1)
      full_install
      ;;
    2)
      uninstall_xray
      full_install
      ;;
    3)
      print_qr_codes
      ;;
    *)
      echo "❌ 无效选项，请重新运行脚本。"
      ;;
  esac
}

# 根据模式执行相应流程
if $AUTO_MODE; then
  full_install
else
  main_menu
fi
