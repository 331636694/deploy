#!/usr/bin/env bash
# ============================================================
#  独角鲸云 · 一键部署
#  支持：VLESS + REALITY + Vision (TCP)  /  Hysteria2 + Salamander (UDP)
#  适用：Debian 11/12/13、Ubuntu 20/22/24、Alpine 3.19+（NAT 容器或独立机）
#  部署时可选 IPv4 / IPv6（主菜单 1/2 = VLESS 的 v4/v6，3/4 = Hysteria2 的 v4/v6）
#  用法：bash <(curl -fsSL https://你的域名/deploy.sh)
#        bash deploy.sh --uninstall   卸载：停服务/删配置/删二进制/删防火墙规则
#        bash deploy.sh --force       强制重新生成配置（会作废旧客户端链接）
# ============================================================
set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info(){ printf "${CYAN}[*]${NC} %s\n" "$*"; }
ok(){   printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn(){ printf "${YELLOW}[!]${NC} %s\n" "$*"; }
die(){  printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }
line(){ printf "${CYAN}────────────────────────────────────────────${NC}\n"; }

# ---------- 通用：v4/v6 探测与地址格式 ----------
has_v4(){
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show 2>/dev/null | grep 'inet ' | grep -qv 'inet 127\.'
  else
    curl -4 -fsS --max-time 6 https://api4.ipify.org >/dev/null 2>&1
  fi
}
has_v6(){
  if command -v ip >/dev/null 2>&1; then
    ip -6 addr show 2>/dev/null | grep 'inet6' | grep -qv -e 'fe80' -e '::1/128'
  else
    curl -6 -fsS --max-time 6 https://api6.ipify.org >/dev/null 2>&1
  fi
}
fmt_addr(){
  # $1=IP → 可直接放进 URI host 的形式（IPv6 自动加方括号）
  case "$1" in
    *:*) printf '[%s]' "$1" ;;
    *)   printf '%s' "$1" ;;
  esac
}
check_stack(){
  case "$STACK" in
    v4) has_v4 || die "本机没有全局 IPv4 地址，无法按 IPv4 部署（选菜单 2/4 走 IPv6）" ;;
    v6) has_v6 || die "本机没有全局 IPv6 地址，无法按 IPv6 部署（选菜单 1/3 走 IPv4）" ;;
  esac
}

# ---------- 固定路径 ----------
XRAY_CONF=/usr/local/etc/xray/config.json
XRAY_META=/usr/local/etc/xray/deploy-info.txt
HY_CONF=/etc/hysteria/config.yaml
HY_META=/etc/hysteria/deploy-info.txt

# ---------- 参数 ----------
STACK="v4"    # v4 | v6，主菜单选择
FORCE=0
DO_UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --force)     FORCE=1 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    -h|--help)
      cat <<'HLP'
用法：
  bash deploy.sh               交互式部署（菜单选协议 + IPv4/IPv6：1/2=VLESS，3/4=Hysteria2）
  bash deploy.sh --force       已部署过时强制重新生成配置（旧客户端链接会失效）
  bash deploy.sh --uninstall   卸载：停服务 / 禁自启 / 删配置 / 删二进制 / 删防火墙规则
说明：重复执行默认「复用已有配置」，不会打断正在使用的客户端。
说明：选 IPv6 要求本机有全局 IPv6 地址；生成的链接自动带 [] 包住的 v6 地址。
支持：Debian / Ubuntu（systemd）、Alpine（OpenRC）。
注意：Alpine 精简镜像若没有 bash，先 apk add bash 再执行本脚本。
HLP
      exit 0 ;;
    *) die "未知参数：$a（支持 --uninstall / --force / -h）" ;;
  esac
done

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo -i 后再执行）"

# ---------- 环境检查 ----------
. /etc/os-release 2>/dev/null || die "无法识别系统"
case "${ID:-}" in
  debian|ubuntu|alpine) : ;;
  *) die "仅支持 Debian / Ubuntu / Alpine，当前：${ID:-未知}" ;;
esac
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的架构：$ARCH" ;;
esac
HAS_SYSTEMD=0
command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && HAS_SYSTEMD=1
HAS_OPENRC=0
command -v rc-service >/dev/null 2>&1 && HAS_OPENRC=1

PKG=""
if command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v apk >/dev/null 2>&1; then PKG=apk
fi

install_deps(){
  case "$PKG" in
    apt) apt-get update -qq && apt-get install -y -qq curl openssl ca-certificates unzip tar >/dev/null ;;
    apk) apk add --no-cache curl openssl ca-certificates unzip tar >/dev/null ;;
    *)   warn "未识别包管理器，请手动装：curl openssl unzip tar" ;;
  esac
}

info "系统：${PRETTY_NAME:-$ID}  架构：${ARCH}  systemd：$([ $HAS_SYSTEMD = 1 ] && echo 有 || echo 无)  openrc：$([ $HAS_OPENRC = 1 ] && echo 有 || echo 无)"
info "网络：IPv4 $(has_v4 && echo 有 || echo 无)  IPv6 $(has_v6 && echo 有 || echo 无)（菜单里按实际选择）"

# ---------- 元数据读写（deploy-info.txt，key=value） ----------
meta_get(){
  # $1=文件 $2=键
  [ -f "$1" ] || return 1
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# ---------- 端口 ----------
pick_port(){
  local p
  while :; do
    read -rp "请输入要使用的端口（30000-60000，直接回车随机）：" p || p=""
    [ -z "$p" ] && p=$(( RANDOM % 30000 + 30000 ))
    case "$p" in
      ''|*[!0-9]*) warn "只能填数字"; continue ;;
    esac
    if [ "$p" -lt 30000 ] || [ "$p" -gt 60000 ]; then
      warn "端口必须在 30000-60000 之间"; continue
    fi
    echo "$p"; return
  done
}
port_owner(){
  if command -v ss >/dev/null 2>&1; then
    ss -lntup 2>/dev/null | grep -E "[:.]$1 " | head -1 | sed -n 's/.*users:(("\([^"]*\)".*/\1/p'
  else
    echo "未知（无 ss 命令）"
  fi
}
port_busy(){
  if command -v ss >/dev/null 2>&1; then
    ss -lntu 2>/dev/null | grep -qE "[:.]$1 " && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lntu 2>/dev/null | grep -qE "[:.]$1 " && return 0
  fi
  return 1
}

# ---------- 通用：放行/收回防火墙 ----------
open_port(){
  # $1=端口 $2=tcp|udp
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$1/$2" >/dev/null 2>&1 && ok "ufw 已放行 $1/$2" || warn "ufw 放行失败，请手动 ufw allow $1/$2"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$1/$2" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 $1/$2" || warn "firewalld 放行失败"
  fi
}
close_port(){
  # $1=端口 $2=tcp|udp  （卸载用；端口为空直接跳过）
  [ -n "${1:-}" ] || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "$1/$2" >/dev/null 2>&1 && ok "ufw 已移除 $1/$2" || warn "ufw 未找到 $1/$2 规则（可能已被删除）"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="$1/$2" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已移除 $1/$2" || warn "firewalld 移除 $1/$2 失败"
  fi
}

# ---------- 通用：取公网 IP（按所选栈 v4/v6） ----------
get_ip(){
  local ip=""
  if [ "$STACK" = "v6" ]; then
    ip="$(curl -6 -fsS --max-time 8 https://api6.ipify.org 2>/dev/null)"
    [ -n "$ip" ] || ip="$(curl -6 -fsS --max-time 8 https://v6.ident.me 2>/dev/null)"
    [ -n "$ip" ] || ip="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | sed -n 's/.* src \([0-9a-fA-F:]*\).*/\1/p' | head -1)"
    case "$ip" in
      ''|*[!0-9a-fA-F:]*) ip="你的IPv6" ;;
    esac
  else
    ip="$(curl -4 -fsS --max-time 8 https://api4.ipify.org 2>/dev/null)"
    [ -n "$ip" ] || ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null)"
    [ -n "$ip" ] || ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    case "$ip" in
      ''|*[!0-9a-fA-F.:]*) ip="你的IPv4" ;;
    esac
  fi
  printf '%s\n' "$ip"
}

# ---------- 通用：写服务 ----------
write_service(){
  # $1=名称 $2=命令行
  if [ $HAS_SYSTEMD = 1 ]; then
    cat > "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=$1
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$2
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$1" >/dev/null 2>&1
    systemctl restart "$1"
    sleep 2
    systemctl is-active --quiet "$1" || die "$1 启动失败，查看：journalctl -u $1 -n 30"
  elif [ $HAS_OPENRC = 1 ]; then
    # OpenRC（Alpine）：supervise-daemon 看护，进程挂掉自动拉起
    local bin args
    bin="${2%% *}"; args="${2#* }"
    [ "$args" = "$2" ] && args=""
    cat > "/etc/init.d/$1" <<EOF
#!/sbin/openrc-run
name="$1"
description="$1"
supervisor="supervise-daemon"
command="$bin"
command_args="$args"
output_log="/var/log/$1.log"
error_log="/var/log/$1.log"
respawn_delay=3
respawn_max=0

depend() {
    need net
    after firewall
}
EOF
    chmod 755 "/etc/init.d/$1"
    rc-update add "$1" default >/dev/null 2>&1
    rc-service "$1" restart >/dev/null 2>&1
    sleep 2
    rc-service "$1" status >/dev/null 2>&1 || die "$1 启动失败，查看：tail -20 /var/log/$1.log"
  else
    warn "没有 systemd，改用 nohup 方式启动（重启后需手动再跑一次本脚本或加 rc.local）"
    pkill -f "$2" >/dev/null 2>&1 || true
    nohup $2 >"/var/log/$1.log" 2>&1 &
    sleep 2
    pgrep -f "$2" >/dev/null || die "$1 启动失败，查看 /var/log/$1.log"
  fi
  ok "$1 已启动"
}

ensure_running(){
  # $1=服务名  （复用已有配置时只保证它在跑，不碰配置）
  if [ $HAS_SYSTEMD != 1 ]; then
    if [ $HAS_OPENRC = 1 ] && [ -x "/etc/init.d/$1" ]; then
      rc-update add "$1" default >/dev/null 2>&1 || true
      if ! rc-service "$1" status >/dev/null 2>&1; then
        warn "$1 当前未运行，正在拉起..."
        rc-service "$1" start >/dev/null 2>&1 || true
        sleep 2
      fi
      rc-service "$1" status >/dev/null 2>&1 && ok "$1 运行中" || die "$1 未能启动，查看：tail -20 /var/log/$1.log"
    fi
    return 0
  fi
  systemctl enable "$1" >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet "$1"; then
    warn "$1 当前未运行，正在拉起..."
    systemctl restart "$1" >/dev/null 2>&1 || true
    sleep 2
  fi
  systemctl is-active --quiet "$1" && ok "$1 运行中" || die "$1 未能启动，查看：journalctl -u $1 -n 30"
}

# ============================================================
#  方案一：VLESS + REALITY + Vision
# ============================================================
show_reality_existing(){
  # 复用已有部署：优先读 deploy-info.txt，没有就从 config.json 里捞。成功返回 0。
  local port uuid sni pub sid priv stack
  stack="$(meta_get "$XRAY_META" STACK)"
  if [ -f "$XRAY_META" ]; then
    port="$(meta_get "$XRAY_META" PORT)"
    uuid="$(meta_get "$XRAY_META" UUID)"
    sni="$(meta_get "$XRAY_META" SNI)"
    pub="$(meta_get "$XRAY_META" PUB)"
    sid="$(meta_get "$XRAY_META" SID)"
  fi
  if [ -z "${uuid:-}" ] || [ -z "${port:-}" ] || [ -z "${pub:-}" ]; then
    [ -f "$XRAY_CONF" ] || return 1
    grep -q '"reality"' "$XRAY_CONF" 2>/dev/null || return 1
    port="$(grep -oE '"port": *[0-9]+' "$XRAY_CONF" | head -1 | grep -oE '[0-9]+')"
    uuid="$(grep -oE '"id": *"[^"]+"' "$XRAY_CONF" | head -1 | sed 's/.*"id": *"//;s/"$//')"
    sni="$(grep -oE '"serverNames": *\[ *"[^"]+"' "$XRAY_CONF" | head -1 | sed 's/.*\[ *"//;s/"$//')"
    sid="$(grep -oE '"shortIds": *\[ *"[^"]+"' "$XRAY_CONF" | head -1 | sed 's/.*\[ *"//;s/"$//')"
    priv="$(grep -oE '"privateKey": *"[^"]+"' "$XRAY_CONF" | head -1 | sed 's/.*"privateKey": *"//;s/"$//')"
    if [ -z "${pub:-}" ] && [ -n "${priv:-}" ] && command -v xray >/dev/null 2>&1; then
      pub="$(xray x25519 -i "$priv" 2>/dev/null | sed -n 's/^Password (PublicKey): *//p' | head -1)"
      [ -n "$pub" ] || pub="$(xray x25519 -i "$priv" 2>/dev/null | sed -n 's/^Public[Kk]ey: *//p' | head -1)"
    fi
  fi
  # 栈来源：元数据 STACK > 配置监听地址 > 当前菜单选择
  if [ -z "${stack:-}" ] && [ -f "$XRAY_CONF" ]; then
    case "$(grep -oE '"listen": *"[^"]+"' "$XRAY_CONF" 2>/dev/null | head -1 | sed 's/.*"//;s/"$//')" in
      ::) stack=v6 ;;
      *)  stack=v4 ;;
    esac
  fi
  [ -n "${stack:-}" ] || stack="$STACK"
  STACK="$stack"
  [ -n "${uuid:-}" ] && [ -n "${port:-}" ] && [ -n "${pub:-}" ] || return 1

  SERVER_IP="$(get_ip)"
  ADDR="$(fmt_addr "$SERVER_IP")"
  LINK="vless://${uuid}@${ADDR}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&headerType=none#%E7%8B%AC%E8%A7%92%E9%B2%B8%E4%BA%91-REALITY"
  echo
  line
  printf "${BOLD}${GREEN}已部署过，复用现有配置${NC}（未改动任何文件，旧客户端继续可用）\n"
  line
  echo "协议：VLESS + REALITY + Vision"
  echo "地址：${ADDR}"
  echo "端口：${port}"
  echo "UUID：${uuid}"
  echo "SNI ：${sni}"
  echo "公钥：${pub}"
  echo "短ID：${sid}"
  echo
  printf "${BOLD}客户端链接（整条复制导入）：${NC}\n"
  echo "$LINK"
  echo
  warn "想重新生成一套（旧链接会立即失效）：bash deploy.sh --force"
  line
  return 0
}

deploy_reality(){
  line; info "部署 VLESS + REALITY + Vision（IPv${STACK#v}）"; line

  # ---- 幂等：已有可用配置就复用，绝不覆盖正在用的服务 ----
  if [ -f "$XRAY_CONF" ] && [ "$FORCE" != 1 ]; then
    if show_reality_existing; then
      ensure_running xray
      return 0
    fi
    warn "检测到已有的 xray 配置但无法解析，将重新生成"
    cp -p "$XRAY_CONF" "$XRAY_CONF.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null && warn "原配置已备份为 config.json.bak.<时间>"
  fi
  if [ "$FORCE" = 1 ]; then
    warn "--force：强制重新生成配置，旧客户端链接将失效"
    # 旧配置先备份，别把客户原来的参数弄丢
    [ -f "$XRAY_CONF" ] && cp -p "$XRAY_CONF" "$XRAY_CONF.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null \
      && warn "旧配置已备份为 config.json.bak.<时间>"
    # 先停掉本脚本自己的服务，否则同端口重跑会被 port_busy 挡死
    if [ $HAS_SYSTEMD = 1 ] && systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service'; then
      systemctl stop xray >/dev/null 2>&1 && ok "已停止旧的 xray（准备替换）"
    elif [ -x /etc/init.d/xray ]; then
      rc-service xray stop >/dev/null 2>&1 && ok "已停止旧的 xray（准备替换）"
    fi
    # 收回旧端口的防火墙规则，避免规则堆积
    if [ -f "$XRAY_META" ]; then
      OLD_PORT="$(meta_get "$XRAY_META" PORT)"
      [ -n "${OLD_PORT:-}" ] && close_port "$OLD_PORT" tcp
    fi
  fi

  check_stack
  PORT="$(pick_port)"
  port_busy "$PORT" && die "端口 $PORT 已被占用（占用者：$(port_owner "$PORT" || echo 未知)），换一个"

  SNI="www.microsoft.com"
  info "伪装目标：$SNI"

  # 装依赖
  if ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    info "安装基础依赖..."
    install_deps
  fi

  # 装 xray
  if ! command -v xray >/dev/null 2>&1; then
    info "安装 Xray..."
    if [ "$PKG" = "apt" ]; then
      bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/tmp/xray-install.log 2>&1 \
        || die "Xray 安装失败，日志：/tmp/xray-install.log"
    else
      # Alpine 等非 systemd 系统：官方安装脚本写死 systemd，改为直接取 release 二进制（静态链接，musl 可跑）
      case "$ARCH" in
        amd64) XZIP="Xray-linux-64.zip" ;;
        arm64) XZIP="Xray-linux-arm64-v8a.zip" ;;
      esac
      rm -rf /tmp/xray-pkg /tmp/xray.zip; mkdir -p /tmp/xray-pkg
      curl -fsSL --max-time 180 -o /tmp/xray.zip \
        "https://github.com/XTLS/Xray-core/releases/latest/download/$XZIP" >/tmp/xray-install.log 2>&1 \
        || die "Xray 下载失败，日志：/tmp/xray-install.log"
      unzip -oq /tmp/xray.zip -d /tmp/xray-pkg >>/tmp/xray-install.log 2>&1 || die "Xray 解压失败"
      head -c 4 /tmp/xray-pkg/xray 2>/dev/null | grep -q ELF || die "下载到的不是可执行文件"
      install -m755 /tmp/xray-pkg/xray /usr/local/bin/xray
      rm -rf /tmp/xray-pkg /tmp/xray.zip
    fi
  fi
  command -v xray >/dev/null 2>&1 || die "Xray 没装上（多半是 GitHub 连不上），日志：/tmp/xray-install.log"
  ok "Xray 版本：$(xray version 2>/dev/null | head -1)"

  # 生成凭据
  UUID="$(xray uuid)"
  KEYPAIR="$(xray x25519)"
  # 兼容各版本输出：PrivateKey / Private key ；Password (PublicKey) / Public key
  PRIV="$(printf '%s\n' "$KEYPAIR" | sed -n 's/^Private[Kk]ey: *//p' | head -1)"
  [ -n "$PRIV" ] || PRIV="$(printf '%s\n' "$KEYPAIR" | sed -n 's/^Private key: *//p' | head -1)"
  PUB="$(printf '%s\n' "$KEYPAIR" | sed -n 's/^Password (PublicKey): *//p' | head -1)"
  [ -n "$PUB" ] || PUB="$(printf '%s\n' "$KEYPAIR" | sed -n 's/^Public[Kk]ey: *//p' | head -1)"
  [ -n "$PUB" ] || PUB="$(printf '%s\n' "$KEYPAIR" | sed -n 's/^Public key: *//p' | head -1)"
  SID="$(openssl rand -hex 8)"
  [ -n "$PRIV" ] && [ -n "$PUB" ] || die "密钥生成失败，原始输出：$KEYPAIR"

  mkdir -p /usr/local/etc/xray
  # v4 监听 0.0.0.0；v6 监听 ::（Linux 默认双栈，v4-mapped 也收）
  if [ "$STACK" = "v6" ]; then LISTEN="::"; else LISTEN="0.0.0.0"; fi
  cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "$LISTEN",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": ["$SID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  chmod 600 "$XRAY_CONF"

  # 配置自检：写坏了绝不重启服务
  TEST_OUT="$(xray run -test -c "$XRAY_CONF" 2>&1)"
  case "$TEST_OUT" in
    *"not defined"*|*"flag provided"*) warn "该 Xray 版本不支持 -test，跳过配置自检" ;;
    *) printf '%s' "$TEST_OUT" | grep -qiE 'failed|error|invalid' \
         && die "生成的配置未通过自检：$TEST_OUT" || ok "配置自检通过" ;;
  esac

  open_port "$PORT" tcp
  write_service xray "xray run -c $XRAY_CONF"

  # 记录客户端参数，供重复执行/卸载时复用
  cat > "$XRAY_META" <<EOF
PORT=$PORT
UUID=$UUID
SNI=$SNI
PUB=$PUB
SID=$SID
STACK=$STACK
EOF
  chmod 600 "$XRAY_META"

  # 取公网 IP
  SERVER_IP="$(get_ip)"
  ADDR="$(fmt_addr "$SERVER_IP")"

  LINK="vless://${UUID}@${ADDR}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#%E7%8B%AC%E8%A7%92%E9%B2%B8%E4%BA%91-REALITY"

  echo
  line
  printf "${BOLD}${GREEN}部署完成${NC}\n"
  line
  echo "协议：VLESS + REALITY + Vision"
  echo "地址：${ADDR}"
  echo "端口：${PORT}"
  echo "UUID：${UUID}"
  echo "SNI ：${SNI}"
  echo "公钥：${PUB}"
  echo "短ID：${SID}"
  echo
  printf "${BOLD}客户端链接（整条复制导入）：${NC}\n"
  echo "$LINK"
  echo
  warn "如果你的机器是 NAT 容器，上面的端口是内网端口，"
  warn "请到控制台把这个端口映射出去，客户端填映射后的公网端口。"
  [ "$STACK" = "v6" ] && warn "IPv6 节点：客户端所在网络必须支持 IPv6 才能连上。"
  line
}

# ============================================================
#  方案二：Hysteria2 + Salamander
# ============================================================
show_hy2_existing(){
  local port pass obfs sni stack
  stack="$(meta_get "$HY_META" STACK)"
  if [ -f "$HY_META" ]; then
    port="$(meta_get "$HY_META" PORT)"
    pass="$(meta_get "$HY_META" PASS)"
    obfs="$(meta_get "$HY_META" OBFS)"
    sni="$(meta_get "$HY_META" SNI)"
  fi
  if [ -z "${pass:-}" ] || [ -z "${port:-}" ] || [ -z "${obfs:-}" ]; then
    [ -f "$HY_CONF" ] || return 1
    port="$(sed -n 's/^listen: *:*//p' "$HY_CONF" | head -1)"
    pass="$(awk '/^auth:/{f=1} f&&/^  password:/{print $2;exit}' "$HY_CONF")"
    obfs="$(awk '/^obfs:/{f=1} f&&/^    password:/{print $2;exit}' "$HY_CONF")"
    sni="$(awk '/^  sni:/{print $2;exit}' "$HY_CONF")"
  fi
  [ -n "${pass:-}" ] && [ -n "${port:-}" ] && [ -n "${obfs:-}" ] || return 1
  [ -n "${sni:-}" ] || sni="www.bing.com"

  # 栈来源：元数据 STACK > 配置监听地址 > 当前菜单选择
  if [ -z "${stack:-}" ] && [ -f "$HY_CONF" ]; then
    case "$(grep -m1 '^listen:' "$HY_CONF" 2>/dev/null)" in
      *'[::]'*) stack=v6 ;;
      *)        stack=v4 ;;
    esac
  fi
  [ -n "${stack:-}" ] || stack="$STACK"
  STACK="$stack"

  SERVER_IP="$(get_ip)"
  ADDR="$(fmt_addr "$SERVER_IP")"
  local insecure
  insecure="$(meta_get "$HY_META" INSECURE 2>/dev/null || true)"
  [ -n "${insecure:-}" ] || insecure=1
  if [ "$insecure" = 1 ]; then
    LINK="hysteria2://${pass}@${ADDR}:${port}/?sni=${sni}&insecure=1&obfs=salamander&obfs-password=${obfs}#%E7%8B%AC%E8%A7%92%E9%B2%B8%E4%BA%91-HY2"
  else
    LINK="hysteria2://${pass}@${ADDR}:${port}/?sni=${sni}&obfs=salamander&obfs-password=${obfs}#%E7%8B%AC%E8%A7%92%E9%B2%B8%E4%BA%91-HY2"
  fi
  echo
  line
  printf "${BOLD}${GREEN}已部署过，复用现有配置${NC}（未改动任何文件，旧客户端继续可用）\n"
  line
  echo "协议：Hysteria2 + Salamander"
  echo "地址：${ADDR}"
  echo "端口：${port}（UDP）"
  echo "密码：${pass}"
  echo "混淆：salamander"
  echo "混淆密码：${obfs}"
  echo
  printf "${BOLD}客户端链接（整条复制导入）：${NC}\n"
  echo "$LINK"
  echo
  if [ "$insecure" = 1 ]; then
    warn "证书是自签的，客户端必须勾选「跳过证书验证」(insecure)。"
  else
    ok "使用真证书（$sni），客户端不需要勾选跳过验证。"
  fi
  warn "想重新生成一套（旧链接会立即失效）：bash deploy.sh --force"
  line
  return 0
}

# 有域名时签真证书（Let's Encrypt / acme.sh standalone，要求 80 端口能从外网访问）
issue_real_cert(){
  local d="$1" myip resolved
  myip="$(get_ip)"
  resolved="$(getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1)"
  [ -n "${resolved:-}" ] || resolved="$(nslookup "$d" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)"
  if [ -n "${resolved:-}" ] && [ "$resolved" != "$myip" ]; then
    warn "域名 $d 解析到 $resolved，本机是 $myip —— 先改解析再来，否则验证必失败"
    return 1
  fi
  if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
    info "安装 acme.sh …"
    curl -fsSL https://get.acme.sh | sh -s email="admin@$d" >/dev/null 2>&1       || { warn "acme.sh 安装失败（网络不通？）"; return 1; }
  fi
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
  info "申请证书：$d（standalone 模式，临时占用 80 端口，约 10~30 秒）"
  if ! "$HOME/.acme.sh/acme.sh" --issue -d "$d" --standalone --httpport 80 >/tmp/acme-issue.log 2>&1; then
    warn "证书签发失败 —— 最常见原因：80 端口没映射到本机，或域名还没解析过来"
    warn "详细日志：/tmp/acme-issue.log"
    return 1
  fi
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$d"     --key-file /etc/hysteria/key.pem     --fullchain-file /etc/hysteria/cert.pem     --reloadcmd "systemctl restart hysteria2 2>/dev/null || rc-service hysteria2 restart 2>/dev/null || true" >/dev/null 2>&1     || { warn "证书安装失败"; return 1; }
  chmod 600 /etc/hysteria/key.pem
  ok "真证书签发成功：$d（每 60 天自动续期，续期后自动重启 hysteria2）"
  return 0
}

deploy_hy2(){
  line; info "部署 Hysteria2 + Salamander 混淆（IPv${STACK#v}）"; line

  # ---- 幂等：已有可用配置就复用 ----
  if [ -f "$HY_CONF" ] && [ "$FORCE" != 1 ]; then
    if show_hy2_existing; then
      ensure_running hysteria2
      return 0
    fi
    warn "检测到已有的 hysteria2 配置但无法解析，将重新生成"
    cp -p "$HY_CONF" "$HY_CONF.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null && warn "原配置已备份为 config.yaml.bak.<时间>"
  fi
  if [ "$FORCE" = 1 ]; then
    warn "--force：强制重新生成配置，旧客户端链接将失效"
    [ -f "$HY_CONF" ] && cp -p "$HY_CONF" "$HY_CONF.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null \
      && warn "旧配置已备份为 config.yaml.bak.<时间>"
    # 先停掉本脚本自己的服务，否则同端口重跑会被 port_busy 挡死
    if [ $HAS_SYSTEMD = 1 ] && systemctl list-unit-files 2>/dev/null | grep -q '^hysteria2\.service'; then
      systemctl stop hysteria2 >/dev/null 2>&1 && ok "已停止旧的 hysteria2（准备替换）"
    elif [ -x /etc/init.d/hysteria2 ]; then
      rc-service hysteria2 stop >/dev/null 2>&1 && ok "已停止旧的 hysteria2（准备替换）"
    fi
    if [ -f "$HY_META" ]; then
      OLD_HPORT="$(meta_get "$HY_META" PORT)"
      [ -n "${OLD_HPORT:-}" ] && close_port "$OLD_HPORT" udp
    fi
  fi

  check_stack
  PORT="$(pick_port)"
  port_busy "$PORT" && die "端口 $PORT 已被占用（占用者：$(port_owner "$PORT" || echo 未知)），换一个"

  if ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    info "安装基础依赖..."
    install_deps
  fi

  if ! command -v hysteria >/dev/null 2>&1; then
    info "安装 Hysteria2..."
    # 版本探测：先走 GitHub API；API 被限流时用 releases/latest 的 302 Location 兜底
    VER="$(curl -fsSL --max-time 15 https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null \
      | grep -oE '"tag_name": *"app/v[0-9.]+"' | grep -oE 'v[0-9.]+' | head -1)"
    if [ -z "${VER:-}" ]; then
      VER="$(curl -fsSI --max-time 15 https://github.com/apernet/hysteria/releases/latest 2>/dev/null \
        | sed -n 's|^[Ll]ocation:.*/tag/app/\(v[0-9.]*\).*|\1|p' | tr -d '\r' | head -1)"
    fi
    [ -n "${VER:-}" ] || VER="v2.6.2"
    info "版本：$VER"
    HY_BASE="https://github.com/apernet/hysteria/releases/download/app%2F${VER}"
    rm -f /tmp/hysteria /tmp/hy.tgz
    # v2.12+ 直接分发裸二进制；老版本是 tar.gz。两种都试，谁通用谁。
    if curl -fsSL --max-time 180 -o /tmp/hysteria "${HY_BASE}/hysteria-linux-${ARCH}" 2>/dev/null; then
      ok "已下载裸二进制（v2.12+ 分发方式）"
    elif curl -fsSL --max-time 180 -o /tmp/hy.tgz "${HY_BASE}/hysteria-linux-${ARCH}.tar.gz" 2>/dev/null; then
      tar -xzf /tmp/hy.tgz -C /tmp hysteria || die "解压失败"
      ok "已下载 tar.gz（老版本分发方式）"
    else
      die "下载失败（版本 ${VER} / 架构 ${ARCH}），检查网络或手动安装"
    fi
    # 防呆：确认下到的是可执行文件而不是错误页
    head -c 4 /tmp/hysteria 2>/dev/null | grep -q ELF || die "下载到的不是可执行文件，可能被网络劫持"
    install -m755 /tmp/hysteria /usr/local/bin/hysteria
    rm -f /tmp/hy.tgz /tmp/hysteria
  fi
  command -v hysteria >/dev/null 2>&1 || die "Hysteria2 没装上（多半是下载失败）"
  # hysteria version 会先打 4 行 ASCII 大横幅，直接 head -1 取到的是空行
  HYVER="$(hysteria version 2>/dev/null | grep -oE 'app/v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "${HYVER:-}" ] || HYVER="$(hysteria version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "${HYVER:-}" ] || HYVER="未知版本"
  ok "Hysteria 版本：$HYVER"

  mkdir -p /etc/hysteria
  # ===== 证书：有域名签真证书，没有就自签 =====
  HY_SNI="www.bing.com"
  HY_INSECURE=1
  if [ -f /etc/hysteria/cert.pem ] && [ -f /etc/hysteria/key.pem ]; then
    ok "检测到已有证书 /etc/hysteria/{cert,key}.pem，直接使用"
    HY_SNI="$(openssl x509 -in /etc/hysteria/cert.pem -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p' | head -1)"
    [ -n "${HY_SNI:-}" ] || HY_SNI="www.bing.com"
    HY_INSECURE=0
  else
    echo
    info "证书：有域名可以签真证书（Let's Encrypt，需要 80 端口能从外网访问）"
    read -rp "  输入域名（直接回车 = 用自签证书）：" HY_DOMAIN || HY_DOMAIN=""
    HY_DOMAIN="$(printf '%s' "${HY_DOMAIN:-}" | tr -d ' ')"
    if [ -n "$HY_DOMAIN" ] && issue_real_cert "$HY_DOMAIN"; then
      HY_SNI="$HY_DOMAIN"
      HY_INSECURE=0
    else
      [ -n "$HY_DOMAIN" ] && warn "改用自签证书"
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
        -days 3650 -subj "/CN=$HY_SNI" >/dev/null 2>&1 || die "证书生成失败"
      chmod 600 /etc/hysteria/key.pem
      HY_INSECURE=1
    fi
  fi

  PASS="$(openssl rand -hex 16)"
  OBFS="$(openssl rand -hex 16)"

  # v4 监听 0.0.0.0；v6 监听 [::]（Linux 默认双栈，v4-mapped 也收）
  if [ "$STACK" = "v6" ]; then HLISTEN="\"[::]:$PORT\""; else HLISTEN="\"0.0.0.0:$PORT\""; fi
  cat > "$HY_CONF" <<EOF
listen: $HLISTEN

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem

auth:
  type: password
  password: $PASS

obfs:
  type: salamander
  salamander:
    password: $OBFS

ignoreClientBandwidth: true

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
  chmod 600 "$HY_CONF"

  open_port "$PORT" udp
  write_service hysteria2 "hysteria server -c $HY_CONF"

  cat > "$HY_META" <<EOF
PORT=$PORT
PASS=$PASS
OBFS=$OBFS
SNI=$HY_SNI
INSECURE=$HY_INSECURE
STACK=$STACK
EOF
  chmod 600 "$HY_META"

  SERVER_IP="$(get_ip)"
  ADDR="$(fmt_addr "$SERVER_IP")"

  if [ "$HY_INSECURE" = 1 ]; then
    LINK="hysteria2://${PASS}@${ADDR}:${PORT}/?sni=${HY_SNI}&insecure=1&obfs=salamander&obfs-password=${OBFS}#%E7%8B%AC%E8%A7%92%E9%B2%B8%E4%BA%91-HY2"
  else
    LINK="hysteria2://${PASS}@${ADDR}:${PORT}/?sni=${HY_SNI}&obfs=salamander&obfs-password=${OBFS}#%E7%8B%AC%E8%A7%92%E9%B2%B8%E4%BA%91-HY2"
  fi

  echo
  line
  printf "${BOLD}${GREEN}部署完成${NC}\n"
  line
  echo "协议：Hysteria2 + Salamander"
  echo "地址：${ADDR}"
  echo "端口：${PORT}（UDP）"
  echo "密码：${PASS}"
  echo "混淆：salamander"
  echo "混淆密码：${OBFS}"
  echo
  printf "${BOLD}客户端链接（整条复制导入）：${NC}\n"
  echo "$LINK"
  echo
  if [ "$HY_INSECURE" = 1 ]; then
    warn "证书是自签的，客户端必须勾选「跳过证书验证」(insecure)。"
  else
    ok "使用真证书（$HY_SNI），客户端不需要勾选跳过验证。"
  fi
  warn "NAT 容器请到控制台映射这个 UDP 端口。"
  [ "$STACK" = "v6" ] && warn "IPv6 节点：客户端所在网络必须支持 IPv6 才能连上。"
  line
}

# ============================================================
#  卸载
# ============================================================
do_uninstall(){
  line; info "卸载：停服务 / 禁自启 / 删配置 / 删二进制 / 删防火墙规则"; line

  local xport="" hport=""
  [ -f "$XRAY_META" ] && xport="$(meta_get "$XRAY_META" PORT)"
  [ -f "$HY_META" ]   && hport="$(meta_get "$HY_META" PORT)"
  # 元数据丢了就从配置里补
  [ -n "${xport:-}" ] || { [ -f "$XRAY_CONF" ] && xport="$(grep -oE '"port": *[0-9]+' "$XRAY_CONF" | head -1 | grep -oE '[0-9]+')"; }
  [ -n "${hport:-}" ] || { [ -f "$HY_CONF" ]   && hport="$(sed -n 's/^listen: *:*//p' "$HY_CONF" | head -1)"; }

  local found=0

  # 1) 停服务 + 禁自启
  for u in xray hysteria2; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${u}\.service"; then
      found=1
      systemctl stop "$u" >/dev/null 2>&1
      systemctl disable "$u" >/dev/null 2>&1
      ok "已停止并禁用：$u"
    elif [ -x "/etc/init.d/$u" ]; then
      found=1
      rc-service "$u" stop >/dev/null 2>&1
      rc-update del "$u" default >/dev/null 2>&1
      ok "已停止并禁用（OpenRC）：$u"
    fi
  done
  # 非 systemd / nohup 兜底
  pkill -f "xray run -c $XRAY_CONF" >/dev/null 2>&1 && ok "已结束残留 xray 进程"
  pkill -f "hysteria server -c $HY_CONF" >/dev/null 2>&1 && ok "已结束残留 hysteria 进程"

  # 1.5) 删 OpenRC 服务脚本（Alpine）
  for f in /etc/init.d/xray /etc/init.d/hysteria2; do
    [ -e "$f" ] && { rm -f "$f"; ok "已删除 $f"; found=1; }
  done

  # 2) 删 systemd unit（含官方安装脚本的 drop-in / 模板单元）
  for f in /etc/systemd/system/xray.service /etc/systemd/system/xray@.service \
           /etc/systemd/system/hysteria2.service; do
    [ -e "$f" ] && { rm -f "$f"; ok "已删除 $f"; found=1; }
  done
  [ -d /etc/systemd/system/xray.service.d ] && { rm -rf /etc/systemd/system/xray.service.d; ok "已删除 xray.service.d/"; }
  if [ $HAS_SYSTEMD = 1 ]; then
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reset-failed >/dev/null 2>&1
  fi

  # 3) 删配置目录
  for d in /usr/local/etc/xray /etc/hysteria /usr/local/share/xray; do
    [ -e "$d" ] && { rm -rf "$d"; ok "已删除 $d"; found=1; }
  done

  # 4) 删二进制
  for b in /usr/local/bin/xray /usr/local/bin/hysteria; do
    [ -e "$b" ] && { rm -f "$b"; ok "已删除 $b"; found=1; }
  done
  rm -f /tmp/xray-install.log /tmp/hy.tgz /tmp/hysteria /tmp/xray.zip 2>/dev/null
  rm -rf /tmp/xray-pkg 2>/dev/null
  rm -f /var/log/xray.log /var/log/hysteria2.log 2>/dev/null

  # 5) 删防火墙规则
  [ -n "${xport:-}" ] && close_port "$xport" tcp
  [ -n "${hport:-}" ] && close_port "$hport" udp

  echo
  if [ $found = 0 ] && [ -z "${xport:-}" ] && [ -z "${hport:-}" ]; then
    ok "未检测到本脚本的部署，无需卸载"
  else
    ok "卸载完成"
  fi

  # 6) 自检
  echo
  info "卸载后自检："
  local left_ports left_units
  if command -v ss >/dev/null 2>&1; then
    left_ports="$(ss -lntup 2>/dev/null | grep -E ':(4[0-9]{4}) ' || true)"
  else
    left_ports="$(netstat -lntup 2>/dev/null | grep -E ':(4[0-9]{4}) ' || true)"
  fi
  if [ $HAS_SYSTEMD = 1 ]; then
    left_units="$(systemctl list-unit-files 2>/dev/null | grep -E 'xray|hysteria' || true)"
  else
    left_units="$(ls /etc/init.d/xray /etc/init.d/hysteria2 2>/dev/null || true)"
  fi
  if [ -z "$left_ports" ] && [ -z "$left_units" ]; then
    ok "端口无残留、unit 无残留"
  else
    [ -n "$left_ports" ] && warn "仍有端口监听：$left_ports"
    [ -n "$left_units" ] && warn "仍有 unit：$left_units"
  fi
  line
}

# ============================================================
#  主菜单
# ============================================================
if [ "$DO_UNINSTALL" = 1 ]; then
  do_uninstall
  exit 0
fi

clear 2>/dev/null || true
cat <<'BANNER'
  ╔══════════════════════════════════════════╗
  ║        独角鲸云 · 一键部署               ║
  ╚══════════════════════════════════════════╝

  请选择协议与 IP 栈（客户端链接自动带对应地址）：

    1) VLESS + REALITY + Vision · IPv4   （TCP，推荐，最隐蔽）
    2) VLESS + REALITY + Vision · IPv6   （纯 v6 机器 / v6 出口）
    3) Hysteria2 + Salamander  · IPv4    （UDP，弱网快）
    4) Hysteria2 + Salamander  · IPv6    （纯 v6 机器 / v6 出口）

    0) 退出
BANNER
echo
read -rp "  输入序号 [1/2/3/4/0]：" CHOICE || CHOICE=0
echo

case "$CHOICE" in
  1) STACK=v4; deploy_reality ;;
  2) STACK=v6; deploy_reality ;;
  3) STACK=v4; deploy_hy2 ;;
  4) STACK=v6; deploy_hy2 ;;
  0) exit 0 ;;
  *) die "无效选择" ;;
esac

echo
info "常用命令："
if [ $HAS_SYSTEMD = 1 ]; then
  echo "  查看状态：systemctl status xray   /  systemctl status hysteria2"
  echo "  查看日志：journalctl -u xray -f   /  journalctl -u hysteria2 -f"
  echo "  重启服务：systemctl restart xray  /  systemctl restart hysteria2"
else
  echo "  查看状态：rc-service xray status  /  rc-service hysteria2 status"
  echo "  查看日志：tail -f /var/log/xray.log  /  tail -f /var/log/hysteria2.log"
  echo "  重启服务：rc-service xray restart /  rc-service hysteria2 restart"
fi
echo "  卸载还原：bash deploy.sh --uninstall"
echo
info "安全提醒：本机禁止使用 HTTP 明文代理、SOCKS4/5、SSR、PPTP 等弱协议，违反会被停机。"
