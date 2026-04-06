#!/usr/bin/env bash
set -euo pipefail

VERSION="v1.0"
SERVICE="mtproxy"
INSTALL_DIR="/opt/MTProxy"
STATE_DIR="/etc/mtproxy-manager"
CONFIG_FILE="$STATE_DIR/config"
SECRET_FILE="$STATE_DIR/secret"

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
    echo -e "${RED}Run as root${NC}"
    exit 1
  fi
}

init_dirs() {
  mkdir -p "$STATE_DIR"
}

is_installed() {
  [[ -d "$INSTALL_DIR" && -f "/etc/systemd/system/${SERVICE}.service" ]]
}

load_config() {
  MT_PORT="$DEFAULT_MT_PORT"
  INTERNAL_PORT="$DEFAULT_INTERNAL_PORT"
  TLS_DOMAIN="$DEFAULT_TLS_DOMAIN"
  SECRET=""

  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
  [[ -f "$SECRET_FILE" ]] && SECRET="$(cat "$SECRET_FILE")"
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
MT_PORT="$MT_PORT"
INTERNAL_PORT="$INTERNAL_PORT"
TLS_DOMAIN="$TLS_DOMAIN"
EOF
}

generate_secret() {
  head -c 16 /dev/urandom | xxd -ps | tr -d '\n'
}

get_server_ip() {
  curl -4 -fsS ifconfig.me 2>/dev/null || curl -4 -fsS icanhazip.com 2>/dev/null || echo "YOUR_IP"
}

build_link() {
  local ip domain_hex
  ip="$(get_server_ip)"
  domain_hex="$(echo -n "$TLS_DOMAIN" | xxd -ps -c 999 | tr -d '\n')"
  echo "tg://proxy?server=${ip}&port=${MT_PORT}&secret=ee${SECRET}${domain_hex}"
}

check_tls_domain() {
  echo -e "${WHITE}Checking TLS domain...${NC}"
  timeout 8 openssl s_client -connect "$1:443" -servername "$1" </dev/null >/tmp/mtproxy_tls_check.out 2>/tmp/mtproxy_tls_check.err
  grep -q "BEGIN CERTIFICATE" /tmp/mtproxy_tls_check.out
}

write_service() {
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=MTProto Proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/objs/bin/mtproto-proxy -u nobody -p ${INTERNAL_PORT} -H ${MT_PORT} -S ${SECRET} -D ${TLS_DOMAIN} --aes-pwd ${INSTALL_DIR}/proxy-secret ${INSTALL_DIR}/proxy-multi.conf --max-accept-rate 1000 --max-dh-accept-rate 500 --msg-buffers-size 134217728 --http-stats
Restart=always
RestartSec=3
TimeoutStopSec=5
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF
}

install_mtproxy() {
  echo -e "${CYAN}Installing MTProxy...${NC}"

  load_config

  read -rp "Client port [${DEFAULT_MT_PORT}]: " input_mt_port
  read -rp "Internal port [${DEFAULT_INTERNAL_PORT}]: " input_internal_port
  read -rp "TLS domain [${DEFAULT_TLS_DOMAIN}]: " input_tls_domain

  MT_PORT="${input_mt_port:-$DEFAULT_MT_PORT}"
  INTERNAL_PORT="${input_internal_port:-$DEFAULT_INTERNAL_PORT}"
  TLS_DOMAIN="${input_tls_domain:-$DEFAULT_TLS_DOMAIN}"

  if ! check_tls_domain "$TLS_DOMAIN"; then
    echo -e "${RED}Invalid TLS domain${NC}"
    sleep 2
    return
  fi

  apt update -y || true
  apt install -y git curl wget build-essential libssl-dev zlib1g-dev ca-certificates openssl xxd iptables-persistent

  rm -rf "$INSTALL_DIR"
  git clone https://github.com/TelegramMessenger/MTProxy "$INSTALL_DIR"

  make -C "$INSTALL_DIR"

  wget -q https://core.telegram.org/getProxySecret -O "${INSTALL_DIR}/proxy-secret"
  wget -q https://core.telegram.org/getProxyConfig -O "${INSTALL_DIR}/proxy-multi.conf"

  SECRET="$(generate_secret)"
  echo "$SECRET" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"

  save_config
  write_service

  iptables -C INPUT -p tcp --dport "$MT_PORT" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -p tcp --dport "$MT_PORT" -j ACCEPT

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi

  systemctl daemon-reload
  systemctl enable "${SERVICE}" >/dev/null 2>&1
  systemctl restart "${SERVICE}"
}

remove_mtproxy() {
  load_config

  systemctl stop "${SERVICE}" 2>/dev/null || true
  systemctl disable "${SERVICE}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE}.service"

  if [[ -n "${MT_PORT:-}" ]]; then
    while iptables -C INPUT -p tcp --dport "$MT_PORT" -j ACCEPT 2>/dev/null; do
      iptables -D INPUT -p tcp --dport "$MT_PORT" -j ACCEPT || break
    done
  fi

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi

  rm -rf "$INSTALL_DIR" "$STATE_DIR"
  systemctl daemon-reload
}

restart_or_start_service() {
  if systemctl is-active --quiet "${SERVICE}"; then
    systemctl restart "${SERVICE}"
  else
    systemctl start "${SERVICE}"
  fi
}

update_mtproxy() {
  load_config

  git -C "$INSTALL_DIR" pull --ff-only
  make -C "$INSTALL_DIR"

  wget -q https://core.telegram.org/getProxySecret -O "${INSTALL_DIR}/proxy-secret"
  wget -q https://core.telegram.org/getProxyConfig -O "${INSTALL_DIR}/proxy-multi.conf"

  systemctl restart "${SERVICE}"
}

change_secret() {
  load_config

  echo -e "${CYAN}1)${NC} Generate new secret"
  echo -e "${CYAN}2)${NC} Enter secret manually"
  echo -en "${YELLOW}Select:${NC} "
  read -r choice

  case "$choice" in
    1) SECRET="$(generate_secret)" ;;
    2)
      read -rp "Enter 32-char hex secret: " SECRET
      [[ "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]] || { echo -e "${RED}Invalid secret${NC}"; sleep 2; return; }
      ;;
    *) echo -e "${RED}Invalid choice${NC}"; sleep 1; return ;;
  esac

  echo "$SECRET" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"

  write_service
  systemctl daemon-reload
  systemctl restart "${SERVICE}"
}

change_tls_domain() {
  load_config

  read -rp "Enter TLS domain [${TLS_DOMAIN}]: " new_domain
  new_domain="${new_domain:-$TLS_DOMAIN}"

  if check_tls_domain "$new_domain"; then
    TLS_DOMAIN="$new_domain"
    save_config
    write_service
    systemctl daemon-reload
    systemctl restart "${SERVICE}"
  else
    echo -e "${RED}Invalid TLS domain${NC}"
    sleep 2
  fi
}

client_ips_raw() {
  ss -Htn state established "( sport = :${MT_PORT} )" \
    | awk '{print $4}' \
    | cut -d: -f1 \
    | sed '/^$/d'
}

client_ip_count() {
  client_ips_raw | sort -u | wc -l
}

show_active_users() {
  load_config

  echo -e "${YELLOW}Total ESTABLISHED connections:${NC}"
  ss -Htn state established "( sport = :${MT_PORT} )" | wc -l

  echo
  echo -e "${YELLOW}Unique IPs:${NC}"
  client_ip_count

  echo
  echo -e "${YELLOW}Top IPs:${NC}"
  client_ips_raw | sort | uniq -c | sort -nr | head -20

  echo
  echo -e "${YELLOW}Stats:${NC}"
  curl -fsS "http://127.0.0.1:${INTERNAL_PORT}/stats" | sed -n '1,20p' || echo "Stats unavailable"
}

status_block() {
  local install_status service_status users link

  if is_installed; then
    install_status="installed"
    service_status="$(systemctl is-active "${SERVICE}" 2>/dev/null || echo "stopped")"
    users="$(client_ip_count || echo 0)"
    link="$(build_link)"
  else
    install_status="not installed"
    service_status="-"
    users="0"
    link="-"
  fi

  echo -e "  ${CYAN}MTProxy Manager by Nikitid${NC}" "${NC}${VERSION}${NC}"
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
      echo -e "${CYAN}3)${NC} Update proxy"
      echo -e "${CYAN}4)${NC} Change secret"
      echo -e "${CYAN}5)${NC} Change TLS domain"
      echo -e "${CYAN}6)${NC} Show active users"
      echo -e "${CYAN}0)${NC} Exit"

      echo
      echo -en "${YELLOW}Select:${NC} "
      read -r choice

      case "$choice" in
        1) remove_mtproxy ;;
        2) restart_or_start_service ;;
        3) update_mtproxy ;;
        4) change_secret ;;
        5) change_tls_domain ;;
        6) show_active_users; echo; read -rp "Enter to continue..." ;;
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
init_dirs
load_config
main_menu
