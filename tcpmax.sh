#!/bin/bash

# 检查是否以 root 用户运行
if [[ $EUID -ne 0 ]]; then
   echo "请以 root 用户权限运行此脚本。"
   exit 1
fi

# 定义配置文件路径
SYSCTL_CONF="/etc/sysctl.conf"
RESOLV_CONF="/etc/resolv.conf"
NETPLAN_DIR="/etc/netplan/"
NM_CONF_DIR="/etc/NetworkManager/conf.d/"
INTERFACES_FILE="/etc/network/interfaces"

# 备份原始配置文件
backup_files() {
  local files=("$SYSCTL_CONF" "$RESOLV_CONF" "$INTERFACES_FILE")
  for file in "${files[@]}"; do
    if [[ -f "$file" ]]; then
      cp "$file" "${file}.$(date +%Y%m%d%H%M%S).bak" || echo "警告：无法备份 $file"
    fi
  done
}
backup_files

# 检测网络管理工具
detect_network_manager() {
  if [[ -d "$NETPLAN_DIR" && $(ls "$NETPLAN_DIR"/*.yaml 2>/dev/null) ]]; then
    echo "netplan"
  elif [[ -d "/etc/NetworkManager" && $(systemctl is-active NetworkManager &>/dev/null) ]]; then
    echo "networkmanager"
  elif [[ -f "$INTERFACES_FILE" && $(grep -q "iface" "$INTERFACES_FILE") ]]; then
    echo "ifupdown"
  else
    echo "unknown"
  fi
}

# MTU 持久化函数：ifupdown
persist_mtu_ifupdown() {
  local iface=$1
  local mtu=$2
  cp "$INTERFACES_FILE" "${INTERFACES_FILE}.$(date +%Y%m%d%H%M%S).bak"
  if grep -q "iface $iface" "$INTERFACES_FILE"; then
    if grep -A 10 "iface $iface" "$INTERFACES_FILE" | grep -q "mtu"; then
      sed -i "/iface $iface/,/^\s*$/ s/mtu .*/mtu $mtu/" "$INTERFACES_FILE"
    else
      sed -i "/iface $iface/a \    mtu $mtu" "$INTERFACES_FILE"
    fi
  else
    echo -e "\nauto $iface\niface $iface inet dhcp\n    mtu $mtu" >> "$INTERFACES_FILE"
  fi
}

# MTU 持久化函数：Netplan
persist_mtu_netplan() {
  local iface=$1
  local mtu=$2
  local netplan_file=$(ls "$NETPLAN_DIR"/*.yaml | head -n1)
  if [[ -f "$netplan_file" ]]; then
    cp "$netplan_file" "${netplan_file}.$(date +%Y%m%d%H%M%S).bak"
    sed -i "/$iface:/a \            mtu: $mtu" "$netplan_file"
  fi
}

# MTU 持久化函数：NetworkManager
persist_mtu_networkmanager() {
  local iface=$1
  local mtu=$2
  local nm_conf_file="$NM_CONF_DIR/99-mtu.conf"
  mkdir -p "$NM_CONF_DIR"
  echo -e "[connection]\nmatch-device=interface-name:$iface\nethernet.mtu=$mtu" > "$nm_conf_file"
}

# MTU 优化模块
optimize_mtu() {
  echo -e "\n>>> 正在优化MTU配置..."
  local target_mtu=1500
  if ip link show | grep -q "tun0"; then
    target_mtu=1420
  elif ip link show | grep -q "wg0"; then
    target_mtu=1420
  fi
  local active_iface
  active_iface=$(ip route get 8.8.8.8 | awk -F"dev " '{print $2}' | awk '{print $1}')
  if [[ -n "$active_iface" ]]; then
    current_mtu=$(cat /sys/class/net/"$active_iface"/mtu)
    if [[ $current_mtu -ne $target_mtu ]]; then
      echo "正在调整 $active_iface 的MTU: $current_mtu → $target_mtu"
      ip link set dev "$active_iface" mtu "$target_mtu" || echo "MTU临时设置失败"
      local network_manager=$(detect_network_manager)
      case "$network_manager" in
        "netplan")
          echo "通过Netplan持久化MTU"
          persist_mtu_netplan "$active_iface" "$target_mtu"
          ;;
        "networkmanager")
          echo "通过NetworkManager持久化MTU"
          persist_mtu_networkmanager "$active_iface" "$target_mtu"
          ;;
        "ifupdown")
          echo "通过ifupdown持久化MTU"
          persist_mtu_ifupdown "$active_iface" "$target_mtu"
          ;;
        *)
          echo "警告：无法找到支持的持久化配置方式"
          ;;
      esac
    else
      echo "$active_iface 的MTU已为 $target_mtu，无需调整。"
    fi
  else
    echo "警告：未检测到活动网络接口"
  fi
}

# DNS 优化模块
optimize_dns() {
  echo -e "\n>>> 正在设置DNS配置..."
  chattr -i "$RESOLV_CONF" 2>/dev/null
  cat > "$RESOLV_CONF" <<EOF
# 由脚本设置的DNS配置
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
  chattr +i "$RESOLV_CONF" 2>/dev/null || echo "警告：无法锁定 $RESOLV_CONF"
}

# TCP 优化模块
optimize_tcp() {
  echo -e "\n>>> 正在优化TCP配置..."
  cp "$SYSCTL_CONF" "${SYSCTL_CONF}.$(date +%Y%m%d%H%M%S).bak" || echo "警告：无法备份 $SYSCTL_CONF"

  # TCP 优化参数
  tcp_params=(
    "fs.file-max=10485760"
    "fs.inotify.max_user_watches=524288"
    "fs.inotify.max_user_instances=524288"
    "vm.swappiness=10"
    "vm.zone_reclaim_mode=0"
    "net.ipv4.tcp_slow_start_after_idle=0"
    "net.ipv4.tcp_ecn=1"
    "net.ipv4.tcp_frto=2"
    "net.ipv4.tcp_mtu_probing=1"
    "net.ipv4.tcp_rfc1337=1"
    "net.core.default_qdisc=fq"
    "net.ipv4.tcp_congestion_control=bbr"
    # "net.ipv4.tcp_available_congestion_control=bbr cubic reno"
    "net.core.rmem_max=134217728"
    "net.core.wmem_max=134217728"
    "net.ipv4.tcp_rmem=4096 524288 134217728"
    "net.ipv4.tcp_wmem=4096 131072 134217728"
    "net.core.somaxconn=65535"
    "net.ipv4.tcp_max_syn_backlog=65535"
    "net.ipv4.tcp_syn_retries=3"
    "net.ipv4.tcp_synack_retries=3"
    "net.ipv4.tcp_fin_timeout=10"
    "net.ipv4.tcp_keepalive_time=600"
    "net.ipv4.tcp_keepalive_intvl=60"
    "net.ipv4.tcp_keepalive_probes=5"
    "net.ipv4.tcp_fastopen=3"
    "net.ipv4.tcp_tw_reuse=1"
    "net.ipv4.udp_rmem_min=65536"
    "net.ipv4.udp_wmem_min=65536"
    "net.ipv4.ip_forward=1"
    "net.ipv4.conf.all.route_localnet=1"
    "net.netfilter.nf_conntrack_max=1048576"
    "net.netfilter.nf_conntrack_buckets=131072"
    "net.netfilter.nf_conntrack_tcp_timeout_established=7200"
    "net.netfilter.nf_conntrack_tcp_timeout_time_wait=30"
  )

  # 将参数写入 sysctl.conf
  for param in "${tcp_params[@]}"; do
    if grep -q "^${param%%=*}" "$SYSCTL_CONF"; then
      sed -i "s|^${param%%=*} *=.*|${param}|" "$SYSCTL_CONF"
    else
      echo "$param" >> "$SYSCTL_CONF"
    fi
  done

  # 使配置立即生效
  sysctl -p > /dev/null
  echo "TCP 优化配置已应用。"
}

# 优化验证模块
validate_optimization() {
  echo -e "\n>>> 优化验证报告："
  active_iface=$(ip route get 8.8.8.8 | awk -F"dev " '{print $2}' | awk '{print $1}')
  current_mtu=$(cat /sys/class/net/"$active_iface"/mtu 2>/dev/null)
  printf "%-25s %-15s => %s\n" "活动接口MTU" "$active_iface" "${current_mtu:-未检测}"
  if command -v dig &>/dev/null; then
    dns_time=$(dig +time=2 +stats www.google.com @1.1.1.1 | grep -i "Query time:" | awk '{print $4 " ms"}')
    printf "%-25s %-15s => %s\n" "DNS响应时间" "1.1.1.1" "${dns_time:-未检测}"
  else
    echo "警告：未找到dig命令，请安装dnsutils或bind-utils以检测DNS响应时间。"
  fi
  echo -e "\n当前DNS配置："
  cat "$RESOLV_CONF"
  echo -e "\n当前TCP参数："
  sysctl net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_fastopen
}

# 执行优化
optimize_mtu
optimize_dns
optimize_tcp
validate_optimization

# 提示用户重启网络服务
echo -e "\n优化完成！为使MTU配置持久化，请重启网络服务："
network_manager=$(detect_network_manager)
case "$network_manager" in
  "netplan")
    echo "  sudo netplan apply"
    ;;
  "networkmanager")
    echo "  sudo systemctl restart NetworkManager"
    ;;
  "ifupdown")
    echo "  sudo systemctl restart networking  # 或 sudo ifdown $active_iface && sudo ifup $active_iface"
    ;;
  *)
    echo "  请手动重启网络服务。"
    ;;
esac
echo -e "\n后续建议："
echo "1. MTU调整后重启网络服务以应用持久化配置。"
echo "2. 测试DNS解析效果：dig www.google.com @1.1.1.1"
echo "3. 如需进一步DNS优化，可考虑配置DNS over TLS/HTTPS。"
echo "4. 检查TCP参数是否生效：sysctl -a | grep tcp"