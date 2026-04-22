#!/usr/bin/env bash
set -euo pipefail

VERSION="v1.2"
SERVICE="mtproxy"
INSTALL_DIR="/opt/MTProxy"
STATE_DIR="/etc/mtproxy-manager"
CONFIG_FILE="$STATE_DIR/config"
SECRET_FILE="$STATE_DIR/secret"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

DEFAULT_MT_PORT="443"
DEFAULT_INTERNAL_PORT="8888"
DEFAULT_TLS_DOMAIN="www.google.com"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    if [[ -n "${SUDO_USER:-}" ]]; then
      echo -e "${RED}Run as root${NC}"
      exit 1
    fi

    echo -e "${RED}Run this script with sudo or as root.${NC}"
    echo -e "${YELLOW}Example:${NC} sudo bash mtproxy-manager.sh"
    exit 1
  fi
}

check_supported_os() {
  if [[ ! -r /etc/os-release ]]; then
    echo -e "${RED}Unsupported OS${NC}"
    exit 1
  fi

  # shellcheck source=/dev/null
  source /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo -e "${RED}Supported only on Ubuntu 22.04 or 24.04${NC}"
    exit 1
  fi

  case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *)
      echo -e "${RED}Supported only on Ubuntu 22.04 or 24.04${NC}"
      exit 1
      ;;
  esac
}

warn_firewall_managers() {
  if systemctl is-active --quiet ufw 2>/dev/null; then
    echo -e "${YELLOW}Warning:${NC} ufw is active. This script supports direct iptables management only."
  fi

  if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo -e "${YELLOW}Warning:${NC} firewalld is active. This script supports direct iptables management only."
  fi
}

init_dirs() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
}

is_installed() {
  [[ -d "$INSTALL_DIR" && -f "$SERVICE_FILE" ]]
}

require_installed() {
  if ! is_installed; then
    echo -e "${RED}MTProxy is not installed${NC}"
    sleep 2
    return 1
  fi
}

load_from_service() {
  local exec_line

  [[ -f "$SERVICE_FILE" ]] || return 0

  exec_line="$(sed -n 's/^ExecStart=//p' "$SERVICE_FILE" | head -n1)"
  [[ -n "$exec_line" ]] || return 0

  local parsed_mt_port parsed_internal_port parsed_tls_domain

  parsed_mt_port="$(sed -n 's/.* -H \([0-9]\+\)\>.*/\1/p' <<<"$exec_line" | head -n1)"
  parsed_internal_port="$(sed -n 's/.* -p \([0-9]\+\)\>.*/\1/p' <<<"$exec_line" | head -n1)"
  parsed_tls_domain="$(sed -n 's/.* -D \([^ ]\+\)\>.*/\1/p' <<<"$exec_line" | head -n1)"

  [[ -n "$parsed_mt_port" ]] && MT_PORT="$parsed_mt_port"
  [[ -n "$parsed_internal_port" ]] && INTERNAL_PORT="$parsed_internal_port"
  [[ -n "$parsed_tls_domain" ]] && TLS_DOMAIN="$parsed_tls_domain"
}

load_config() {
  MT_PORT="$DEFAULT_MT_PORT"
  INTERNAL_PORT="$DEFAULT_INTERNAL_PORT"
  TLS_DOMAIN="$DEFAULT_TLS_DOMAIN"
  SECRET=""

  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  else
    load_from_service
  fi

  if [[ -f "$SECRET_FILE" ]]; then
    SECRET="$(tr -d '\r\n' < "$SECRET_FILE")"
  fi
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
MT_PORT="$MT_PORT"
INTERNAL_PORT="$INTERNAL_PORT"
TLS_DOMAIN="$TLS_DOMAIN"
EOF
  chmod 600 "$CONFIG_FILE"
}

generate_secret() {
  head -c 16 /dev/urandom | xxd -ps | tr -d '\n'
}

download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$output"
  else
    echo -e "${RED}Neither curl nor wget is available${NC}"
    return 1
  fi
}

get_server_ip() {
  local ip

  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "src") {
        print $(i+1)
        exit
      }
    }
  }')"

  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi

  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi

  return 1
}

build_link() {
  local ip domain_hex

  ip="$(get_server_ip 2>/dev/null || true)"
  ip="${ip:-YOUR_IP}"

  domain_hex="$(printf '%s' "$TLS_DOMAIN" | xxd -ps -c 999 | tr -d '\n')"
  echo "tg://proxy?server=${ip}&port=${MT_PORT}&secret=ee${SECRET}${domain_hex}"
}

check_tls_domain() {
  local domain="$1"
  local tmp

  tmp="$(mktemp)"

  if timeout 8 openssl s_client \
    -connect "${domain}:443" \
    -servername "$domain" \
    -verify_hostname "$domain" \
    -verify_return_error \
    </dev/null >"$tmp" 2>&1; then
    if grep -q "Verify return code: 0 (ok)" "$tmp"; then
      rm -f "$tmp"
      return 0
    fi
  fi

  rm -f "$tmp"
  return 1
}

validate_port() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 )) || return 1

  return 0
}

port_in_use() {
  local port="$1"

  if ss -H -ltn "( sport = :${port} )" 2>/dev/null | grep -q .; then
    return 0
  fi

  return 1
}

check_required_commands() {
  local missing=()

  for cmd in git make openssl timeout ss iptables systemctl xxd ip curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo -e "${RED}Missing required commands:${NC} ${missing[*]}"
    return 1
  fi
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MTProto Proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStartPre=/usr/bin/test -x ${INSTALL_DIR}/objs/bin/mtproto-proxy
ExecStartPre=/usr/bin/test -f ${INSTALL_DIR}/proxy-secret
ExecStartPre=/usr/bin/test -f ${INSTALL_DIR}/proxy-multi.conf
ExecStart=${INSTALL_DIR}/objs/bin/mtproto-proxy -u nobody -p ${INTERNAL_PORT} -H ${MT_PORT} -S ${SECRET} -D ${TLS_DOMAIN} --aes-pwd ${INSTALL_DIR}/proxy-secret ${INSTALL_DIR}/proxy-multi.conf --max-accept-rate 1000 --max-dh-accept-rate 500 --msg-buffers-size 134217728 --http-stats
Restart=always
RestartSec=3
TimeoutStopSec=5
TimeoutStartSec=20
LimitNOFILE=100000
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
PrivateDevices=true
ProtectControlGroups=true
ProtectKernelTunables=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
}

verify_service_started() {
  local attempts=10

  while (( attempts > 0 )); do
    if systemctl is-active --quiet "${SERVICE}"; then
      return 0
    fi
    sleep 1
    ((attempts--))
  done

  echo -e "${RED}Service failed to start${NC}"
  echo
  systemctl --no-pager --full status "${SERVICE}" || true
  echo
  journalctl -u "${SERVICE}" -n 30 --no-pager || true
  return 1
}

ensure_firewall_rule() {
  iptables -C INPUT -p tcp --dport "$MT_PORT" -m comment --comment "mtproxy-manager" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p tcp --dport "$MT_PORT" -m comment --comment "mtproxy-manager" -j ACCEPT

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

remove_firewall_rule() {
  while iptables -C INPUT -p tcp --dport "$MT_PORT" -m comment --comment "mtproxy-manager" -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p tcp --dport "$MT_PORT" -m comment --comment "mtproxy-manager" -j ACCEPT || break
  done

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

prompt_install_settings() {
  local input_mt_port input_internal_port input_tls_domain

  read -rp "Client port [${DEFAULT_MT_PORT}]: " input_mt_port
  read -rp "Internal port [${DEFAULT_INTERNAL_PORT}]: " input_internal_port
  read -rp "TLS domain [${DEFAULT_TLS_DOMAIN}]: " input_tls_domain

  MT_PORT="${input_mt_port:-$DEFAULT_MT_PORT}"
  INTERNAL_PORT="${input_internal_port:-$DEFAULT_INTERNAL_PORT}"
  TLS_DOMAIN="${input_tls_domain:-$DEFAULT_TLS_DOMAIN}"

  if ! validate_port "$MT_PORT"; then
    echo -e "${RED}Invalid client port${NC}"
    return 1
  fi

  if ! validate_port "$INTERNAL_PORT"; then
    echo -e "${RED}Invalid internal port${NC}"
    return 1
  fi

  if [[ "$MT_PORT" == "$INTERNAL_PORT" ]]; then
    echo -e "${RED}Client port and internal port must be different${NC}"
    return 1
  fi

  if port_in_use "$MT_PORT"; then
    echo -e "${RED}Client port ${MT_PORT} is already in use${NC}"
    return 1
  fi

  if port_in_use "$INTERNAL_PORT"; then
    echo -e "${RED}Internal port ${INTERNAL_PORT} is already in use${NC}"
    return 1
  fi

  echo -e "${WHITE}Checking TLS domain...${NC}"
  if ! check_tls_domain "$TLS_DOMAIN"; then
    echo -e "${RED}Invalid TLS domain or certificate chain verification failed${NC}"
    return 1
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    git curl wget build-essential libssl-dev zlib1g-dev \
    ca-certificates openssl xxd iptables iptables-persistent iproute2
}

install_mtproxy() {
  echo -e "${CYAN}Installing MTProxy...${NC}"

  load_config
  prompt_install_settings || { sleep 2; return; }

  install_packages
  check_required_commands || { sleep 2; return; }

  rm -rf "$INSTALL_DIR"
  git clone --depth 1 https://github.com/TelegramMessenger/MTProxy "$INSTALL_DIR"
  make -C "$INSTALL_DIR"

  if [[ ! -x "${INSTALL_DIR}/objs/bin/mtproto-proxy" ]]; then
    echo -e "${RED}Build failed: mtproto-proxy binary not found${NC}"
    sleep 2
    return
  fi

  download_file "https://core.telegram.org/getProxySecret" "${INSTALL_DIR}/proxy-secret"
  download_file "https://core.telegram.org/getProxyConfig" "${INSTALL_DIR}/proxy-multi.conf"

  SECRET="$(generate_secret)"
  printf '%s\n' "$SECRET" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"

  save_config
  write_service
  ensure_firewall_rule

  systemctl daemon-reload
  systemctl enable "${SERVICE}" >/dev/null 2>&1
  systemctl restart "${SERVICE}"

  if verify_service_started; then
    echo
    echo -e "${GREEN}MTProxy installed successfully${NC}"
    echo -e "${YELLOW}Link:${NC} $(build_link)"
    echo
    read -rp "Press Enter to continue..."
  else
    read -rp "Press Enter to continue..."
  fi
}

remove_mtproxy() {
  require_installed || return
  load_config

  systemctl stop "${SERVICE}" 2>/dev/null || true
  systemctl disable "${SERVICE}" 2>/dev/null || true
  rm -f "$SERVICE_FILE"

  if [[ -n "${MT_PORT:-}" ]]; then
    remove_firewall_rule
  fi

  rm -rf "$INSTALL_DIR" "$STATE_DIR"
  systemctl daemon-reload

  echo -e "${GREEN}MTProxy removed${NC}"
  sleep 2
}

restart_or_start_service() {
  require_installed || return
  check_required_commands || { sleep 2; return; }

  if systemctl is-active --quiet "${SERVICE}"; then
    systemctl restart "${SERVICE}"
  else
    systemctl start "${SERVICE}"
  fi

  if verify_service_started; then
    echo -e "${GREEN}Service is running${NC}"
  fi

  sleep 2
}

stop_service() {
  require_installed || return

  systemctl stop "${SERVICE}"

  echo -e "${GREEN}Service stopped${NC}"
  sleep 2
}

update_mtproxy() {
  require_installed || return
  check_required_commands || { sleep 2; return; }
  load_config

  git -C "$INSTALL_DIR" pull --ff-only
  make -C "$INSTALL_DIR"

  if [[ ! -x "${INSTALL_DIR}/objs/bin/mtproto-proxy" ]]; then
    echo -e "${RED}Build failed: mtproto-proxy binary not found${NC}"
    sleep 2
    return
  fi

  download_file "https://core.telegram.org/getProxySecret" "${INSTALL_DIR}/proxy-secret"
  download_file "https://core.telegram.org/getProxyConfig" "${INSTALL_DIR}/proxy-multi.conf"

  systemctl restart "${SERVICE}"

  if verify_service_started; then
    echo -e "${GREEN}MTProxy updated successfully${NC}"
  fi

  sleep 2
}

change_secret() {
  require_installed || return
  load_config

  echo -e "${CYAN}1)${NC} Generate new secret"
  echo -e "${CYAN}2)${NC} Enter secret manually"
  echo -en "${YELLOW}Select:${NC} "
  read -r choice

  case "$choice" in
    1)
      SECRET="$(generate_secret)"
      ;;
    2)
      read -rp "Enter 32-char hex secret: " SECRET
      if [[ ! "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo -e "${RED}Invalid secret${NC}"
        sleep 2
        return
      fi
      SECRET="${SECRET,,}"
      ;;
    *)
      echo -e "${RED}Invalid choice${NC}"
      sleep 1
      return
      ;;
  esac

  printf '%s\n' "$SECRET" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"

  write_service
  systemctl daemon-reload
  systemctl restart "${SERVICE}"

  if verify_service_started; then
    echo -e "${GREEN}Secret updated${NC}"
  fi

  sleep 2
}

change_tls_domain() {
  require_installed || return
  load_config

  read -rp "Enter TLS domain [${TLS_DOMAIN}]: " new_domain
  new_domain="${new_domain:-$TLS_DOMAIN}"

  echo -e "${WHITE}Checking TLS domain...${NC}"
  if check_tls_domain "$new_domain"; then
    TLS_DOMAIN="$new_domain"
    save_config
    write_service
    systemctl daemon-reload
    systemctl restart "${SERVICE}"

    if verify_service_started; then
      echo -e "${GREEN}TLS domain updated${NC}"
    fi
  else
    echo -e "${RED}Invalid TLS domain or certificate chain verification failed${NC}"
  fi

  sleep 2
}

client_ips_raw() {
  ss -Htn state established "( sport = :${MT_PORT} )" 2>/dev/null \
    | awk '{print $4}' \
    | cut -d: -f1 \
    | sed '/^$/d'
}

client_ip_count() {
  client_ips_raw | sort -u | wc -l
}

show_active_ips() {
  require_installed || return
  load_config

  echo -e "${YELLOW}Total ESTABLISHED connections:${NC}"
  ss -Htn state established "( sport = :${MT_PORT} )" 2>/dev/null | wc -l

  echo
  echo -e "${YELLOW}Unique active IPs:${NC}"
  client_ip_count

  echo
  echo -e "${YELLOW}Top client IPs:${NC}"
  client_ips_raw | sort | uniq -c | sort -nr | head -20

  echo
  echo -e "${YELLOW}Stats:${NC}"
  curl -fsS "http://127.0.0.1:${INTERNAL_PORT}/stats" | sed -n '1,20p' || echo "Stats unavailable"
}

show_logs() {
  require_installed || return
  journalctl -u "${SERVICE}" -n 50 --no-pager || true
  echo
  read -rp "Press Enter to continue..."
}

status_block() {
  local install_status service_status users link

  if is_installed; then
    install_status="installed"
    service_status="$(systemctl is-active "${SERVICE}" 2>/dev/null || echo "stopped")"
    users="$(client_ip_count 2>/dev/null || echo 0)"
    link="$(build_link)"
  else
    install_status="not installed"
    service_status="-"
    users="0"
    link="-"
  fi

  echo -e "  ${CYAN}MTProxy Manager by Nikitid${NC}"
  echo -e "                 ${VERSION}"
  echo

  printf "${YELLOW}%-19s ${GREEN}%s${NC}\n" "Install status:" "$install_status"
  printf "${YELLOW}%-19s ${GREEN}%s${NC}\n" "Service status:" "$service_status"
  printf "${YELLOW}%-19s ${GREEN}%s${NC}\n" "Port:" "${MT_PORT:-}"
  printf "${YELLOW}%-19s ${GREEN}%s${NC}\n" "Internal port:" "${INTERNAL_PORT:-}"
  printf "${YELLOW}%-19s ${GREEN}%s${NC}\n" "TLS domain:" "${TLS_DOMAIN:-}"
  printf "${YELLOW}%-19s ${GREEN}%s${NC}\n" "Active IPs:" "$users"

  echo
  printf "${YELLOW}%-19s ${GREEN}%s${NC}\n" "Link:" "$link"
  echo
}

main_menu() {
  local choice service_action

  while true; do
    clear
    load_config
    status_block

    if is_installed; then
      if systemctl is-active --quiet "${SERVICE}"; then
        service_action="Restart proxy"
      else
        service_action="Start proxy"
      fi

      echo -e "${CYAN}1)${NC} Remove proxy"
      echo -e "${CYAN}2)${NC} ${service_action}"
      echo -e "${CYAN}3)${NC} Stop proxy"
      echo -e "${CYAN}4)${NC} Update proxy"
      echo -e "${CYAN}5)${NC} Change secret"
      echo -e "${CYAN}6)${NC} Change TLS domain"
      echo -e "${CYAN}7)${NC} Show active IPs"
      echo -e "${CYAN}8)${NC} Show logs"
      echo -e "${CYAN}0)${NC} Exit"
      echo
      echo -en "${YELLOW}Select:${NC} "
      read -r choice

      case "$choice" in
        1) remove_mtproxy ;;
        2) restart_or_start_service ;;
        3) stop_service ;;
        4) update_mtproxy ;;
        5) change_secret ;;
        6) change_tls_domain ;;
        7) show_active_ips; echo; read -rp "Press Enter to continue..." ;;
        8) show_logs ;;
        0) exit 0 ;;
        *) ;;
      esac
    else
      echo -e "${CYAN}1)${NC} Install proxy"
      echo -e "${CYAN}0)${NC} Exit"
      echo
      echo -en "${YELLOW}Select:${NC} "
      read -r choice

      case "$choice" in
        1) install_mtproxy ;;
        0) exit 0 ;;
        *) ;;
      esac
    fi
  done
}

ensure_root
check_supported_os
warn_firewall_managers
init_dirs
load_config
main_menu
