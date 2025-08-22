#!/usr/bin/env bash
# bsnapd.sh
# Project: BSnapD - https://github.com/linux-brat/BSnapD/
# Installs a `bsnap` command and provides a TUI to manage:
# - snapd.socket
# - snapd.apparmor.service
# Fixes enabled-status after disable (daemon-reload + unmask + is-enabled check)
# Adds green/red status badges
# Auto-installs snapd if not present, then opens the manager

set -euo pipefail

APP_NAME="bsnap"
INSTALL_PATH="/usr/local/bin/${APP_NAME}"
SERVICES=("snapd.socket" "snapd.apparmor.service")

ASCII_LOGO=$'██████╗░░██████╗███╗░░██╗░█████╗░██████╗░██████╗░\n██╔══██╗██╔════╝████╗░██║██╔══██╗██╔══██╗██╔══██╗\n██████╦╝╚█████╗░██╔██╗██║███████║██████╔╝██║░░██║\n██╔══██╗░╚═══██╗██║╚████║██╔══██║██╔═══╝░██║░░██║\n██████╦╝██████╔╝██║░╚███║██║░░██║██║░░░░░██████╔╝\n╚═════╝░╚═════╝░╚═╝░░╚══╝╚═╝░░╚═╝╚═╝░░░░░╚═════╝░'

# Colors
BOLD="\033[1m"; NC="\033[0m"
C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_INFO="\033[36m"
BADGE_GREEN_BG="\033[48;5;22m\033[38;5;255m"
BADGE_RED_BG="\033[48;5;52m\033[38;5;255m"
BADGE_YELLOW_BG="\033[48;5;178m\033[38;5;0m"
BADGE_OFF="\033[0m"

border="============================================================"

c_bold(){ printf "${BOLD}%s${NC}\n" "$*"; }
c_ok(){ printf "${C_OK}%s${NC}\n" "$*"; }
c_warn(){ printf "${C_WARN}%s${NC}\n" "$*"; }
c_err(){ printf "${C_ERR}%s${NC}\n" "$*"; }
c_info(){ printf "${C_INFO}%s${NC}\n" "$*"; }
pause(){ read -rp "Press Enter to continue..." _; }

badge_active(){ # Active/Inactive badge
  if [[ "$1" == "Active" ]]; then printf "${BADGE_GREEN_BG} ACTIVE ${BADGE_OFF}"; else printf "${BADGE_RED_BG} INACTIVE ${BADGE_OFF}"; fi
}
badge_enabled(){ # Enabled/Disabled/Static/Indirect
  case "$1" in
    Enabled|enabled) printf "${BADGE_GREEN_BG} ENABLED ${BADGE_OFF}" ;;
    Disabled|disabled) printf "${BADGE_RED_BG} DISABLED ${BADGE_OFF}" ;;
    static) printf "${BADGE_YELLOW_BG} STATIC ${BADGE_OFF}" ;;
    indirect) printf "${BADGE_YELLOW_BG} INDIRECT ${BADGE_OFF}" ;;
    masked) printf "${BADGE_RED_BG} MASKED ${BADGE_OFF}" ;;
    *) printf "${BADGE_YELLOW_BG} $1 ${BADGE_OFF}" ;;
  esac
}

pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v zypper >/dev/null 2>&1; then echo "zypper"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  else echo "unknown"
  fi
}

is_snap_installed(){ command -v snap >/dev/null 2>&1; }

active_status(){
  local s=$1
  systemctl is-active --quiet "$s" && echo "Active" || echo "Inactive"
}
enabled_status(){
  local s=$1
  # Use show -p UnitFileState to avoid localization quirks
  local state
  state=$(systemctl show -p UnitFileState --value "$s" 2>/dev/null || echo "unknown")
  echo "$state"
}

enable_service(){
  local s=$1
  # Unmask just in case
  sudo systemctl unmask "$s" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "$s"; then
    c_warn "[$s] is already ON"
  else
    if sudo systemctl enable "$s" >/dev/null 2>&1; then
      sudo systemctl start "$s" || true
      sudo systemctl daemon-reload || true
      c_ok "[$s] has been turned ON"
    else
      c_err "Failed to enable [$s]"
    fi
  fi
}

disable_service(){
  local s=$1
  # Stop first, then disable; reload to reflect UnitFileState immediately
  if ! systemctl is-active --quiet "$s"; then
    c_warn "[$s] is already OFF"
  else
    sudo systemctl stop "$s" || true
    c_ok "[$s] has been stopped"
  fi
  if systemctl is-enabled --quiet "$s"; then
    if sudo systemctl disable "$s" >/dev/null 2>&1; then
      sudo systemctl daemon-reload || true
      c_ok "[$s] has been disabled"
    else
      c_err "Failed to disable [$s]"
    fi
  else
    c_warn "[$s] is already disabled (or static/indirect)"
  fi
}

install_snapd_flow(){
  clear
  c_bold "$ASCII_LOGO"
  echo
  c_bold "$border"
  c_bold "  Snapd Installation"
  c_bold "$border"
  local mgr; mgr="$(pkg_mgr)"
  c_info "Detected package manager: $mgr"

  case "$mgr" in
    apt)
      c_info "Updating apt and installing snapd + apparmor..."
      sudo apt-get update -y
      sudo apt-get install -y snapd apparmor || true
      ;;
    dnf)
      c_info "Installing snapd..."
      sudo dnf install -y snapd || true
      ;;
    yum)
      c_info "Installing snapd..."
      sudo yum install -y epel-release || true
      sudo yum install -y snapd || true
      ;;
    zypper)
      c_info "Installing snapd..."
      sudo zypper --non-interactive install snapd || true
      ;;
    pacman)
      c_info "Installing snapd..."
      sudo pacman -Syu --noconfirm snapd || {
        c_err "Failed to install snapd via pacman. Enable required repos or use AUR."
        pause; return 1
      }
      ;;
    *)
      c_err "Unsupported package manager. Please install snapd manually."
      pause; return 1
      ;;
  esac

  c_info "Enabling snap services..."
  sudo systemctl unmask snapd.socket snapd.apparmor.service >/dev/null 2>&1 || true
  sudo systemctl enable --now snapd.socket || true
  sudo systemctl enable --now snapd.apparmor.service || true
  sudo systemctl daemon-reload || true

  if [ ! -e /snap ] && [ -d /var/lib/snapd/snap ]; then
    c_info "Creating /snap symlink -> /var/lib/snapd/snap ..."
    sudo ln -s /var/lib/snapd/snap /snap || true
  fi

  c_ok "Snapd installation step completed."
  pause
}

service_menu(){
  local svc="$1"
  while true; do
    clear
    c_bold "$ASCII_LOGO"
    echo
    c_bold "$border"
    c_bold "  Service: $svc"
    c_bold "$border"
    local a e
    a=$(active_status "$svc")
    e=$(enabled_status "$svc")
    printf "  Status: %s  |  %s\n" "$(badge_active "$a")" "$(badge_enabled "$e")"
    echo
    echo "  1) Turn ON (enable + start)"
    echo "  2) Turn OFF (stop + disable)"
    echo "  b) Back"
    echo
    read -rp "Choose: " act
    case "$act" in
      1) enable_service "$svc"; pause ;;
      2) disable_service "$svc"; pause ;;
      b|B) return ;;
      *) c_warn "Invalid option"; pause ;;
    esac
  done
}

manager_ui(){
  while true; do
    clear
    c_bold "$ASCII_LOGO"
    echo
    c_bold "$border"
    c_bold "  BSnapD • Snap Services Manager"
    c_bold "$border"

    if ! is_snap_installed; then
      c_warn "snap is NOT installed."
      echo "  Installing snapd now..."
      install_snapd_flow
    fi
    c_ok "snap is installed."

    echo
    echo "Services Status:"
    for i in "${!SERVICES[@]}"; do
      s="${SERVICES[$i]}"
      a=$(active_status "$s")
      e=$(enabled_status "$s")
      printf "  %d) %-28s [ %s | %s ]\n" \
        "$((i+1))" "$s" "$(badge_active "$a")" "$(badge_enabled "$e")"
    done
    echo "  r) Refresh"
    echo "  q) Quit"
    echo
    read -rp "Select a service number, or option: " choice
    case "$choice" in
      q|Q) exit 0 ;;
      r|R) continue ;;
      * )
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#SERVICES[@]} )); then
          service_menu "${SERVICES[$((choice-1))]}"
        else
          c_warn "Invalid selection"; pause
        fi
        ;;
    esac
  done
}

install_self(){
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
SERVICES=("snapd.socket" "snapd.apparmor.service")

BOLD="\033[1m"; NC="\033[0m"
C_OK="\033[32m"; C_WARN="\033[33m"
BADGE_GREEN_BG="\033[48;5;22m\033[38;5;255m"
BADGE_RED_BG="\033[48;5;52m\033[38;5;255m"
BADGE_YELLOW_BG="\033[48;5;178m\033[38;5;0m"
BADGE_OFF="\033[0m"
border="============================================================"
ASCII_LOGO=$'██████╗░░██████╗███╗░░██╗░█████╗░██████╗░██████╗░\n██╔══██╗██╔════╝████╗░██║██╔══██╗██╔══██╗██╔══██╗\n██████╦╝╚█████╗░██╔██╗██║███████║██████╔╝██║░░██║\n██╔══██╗░╚═══██╗██║╚████║██╔══██║██╔═══╝░██║░░██║\n██████╦╝██████╔╝██║░╚███║██║░░██║██║░░░░░██████╔╝\n╚═════╝░╚═════╝░╚═╝░░╚══╝╚═╝░░╚═╝╚═╝░░░░░╚═════╝░'
pause(){ read -rp "Press Enter to continue..." _; }
c_bold(){ printf "${BOLD}%s${NC}\n" "$*"; }
c_ok(){ printf "${C_OK}%s${NC}\n" "$*"; }
c_warn(){ printf "${C_WARN}%s${NC}\n" "$*"; }
badge_active(){ if [[ "$1" == "Active" ]]; then printf "${BADGE_GREEN_BG} ACTIVE ${BADGE_OFF}"; else printf "${BADGE_RED_BG} INACTIVE ${BADGE_OFF}"; fi; }
badge_enabled(){ case "$1" in Enabled|enabled) printf "${BADGE_GREEN_BG} ENABLED ${BADGE_OFF}";; Disabled|disabled) printf "${BADGE_RED_BG} DISABLED ${BADGE_OFF}";; static) printf "${BADGE_YELLOW_BG} STATIC ${BADGE_OFF}";; indirect) printf "${BADGE_YELLOW_BG} INDIRECT ${BADGE_OFF}";; masked) printf "${BADGE_RED_BG} MASKED ${BADGE_OFF}";; *) printf "${BADGE_YELLOW_BG} $1 ${BADGE_OFF}";; esac; }
is_snap_installed(){ command -v snap >/dev/null 2>&1; }
active_status(){ local s=$1; systemctl is-active --quiet "$s" && echo "Active" || echo "Inactive"; }
enabled_status(){ local s=$1; systemctl show -p UnitFileState --value "$s" 2>/dev/null || echo "unknown"; }
enable_service(){ local s=$1; sudo systemctl unmask "$s" >/dev/null 2>&1 || true; if systemctl is-active --quiet "$s"; then c_warn "[$s] is already ON"; else if sudo systemctl enable "$s" >/dev/null 2>&1; then sudo systemctl start "$s" || true; sudo systemctl daemon-reload || true; c_ok "[$s] has been turned ON"; else echo "Failed to enable [$s]"; fi; fi; }
disable_service(){ local s=$1; if ! systemctl is-active --quiet "$s"; then c_warn "[$s] is already OFF"; else sudo systemctl stop "$s" || true; c_ok "[$s] has been stopped"; fi; if systemctl is-enabled --quiet "$s"; then if sudo systemctl disable "$s" >/dev/null 2>&1; then sudo systemctl daemon-reload || true; c_ok "[$s] has been disabled"; else echo "Failed to disable [$s]"; fi; else c_warn "[$s] is already disabled (or static/indirect)"; fi; }
service_menu(){ local svc="$1"; while true; do clear; c_bold "$ASCII_LOGO"; echo; c_bold "$border"; c_bold "  Service: $svc"; c_bold "$border"; local a e; a=$(active_status "$svc"); e=$(enabled_status "$svc"); printf "  Status: %s  |  %s\n" "$(badge_active "$a")" "$(badge_enabled "$e")"; echo; echo "  1) Turn ON (enable + start)"; echo "  2) Turn OFF (stop + disable)"; echo "  b) Back"; echo; read -rp "Choose: " act; case "$act" in 1) enable_service "$svc"; pause ;; 2) disable_service "$svc"; pause ;; b|B) return ;; *) echo "Invalid option"; pause ;; esac; done; }
manager_ui(){ while true; do clear; c_bold "$ASCII_LOGO"; echo; c_bold "$border"; c_bold "  BSnapD • Snap Services Manager"; c_bold "$border"; if ! is_snap_installed; then echo "snap not detected. Install with the installer (bsnapd.sh)."; echo "q) Quit"; read -rp "Choose: " ch; case "$ch" in q|Q) exit 0;; *) continue;; esac; fi; c_ok "snap is installed."; echo; echo "Services Status:"; for i in "${!SERVICES[@]}"; do s="${SERVICES[$i]}"; a=$(active_status "$s"); e=$(enabled_status "$s"); printf "  %d) %-28s [ %s | %s ]\n" "$((i+1))" "$s" "$(badge_active "$a")" "$(badge_enabled "$e")"; done; echo "  r) Refresh"; echo "  q) Quit"; echo; read -rp "Select a service number, or option: " choice; case "$choice" in q|Q) exit 0 ;; r|R) continue ;; * ) if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#SERVICES[@]} )); then service_menu "${SERVICES[$((choice-1))]}"; else echo "Invalid selection"; pause; fi ;; esac; done; }
manager_ui
EOS
  sudo install -m 0755 "$tmp" "$INSTALL_PATH"
  rm -f "$tmp"
  c_ok "Installed ${APP_NAME} to ${INSTALL_PATH}"
}

installer_ui(){
  while true; do
    clear
    c_bold "$ASCII_LOGO"; echo
    c_bold "$border"
    c_bold "  BSnapD • Installer"
    c_bold "$border"
    echo "  Repo: https://github.com/linux-brat/BSnapD/"
    echo
    echo "  1) Install/Update bsnap command"
    echo "  2) Manage snap services now"
    echo "  q) Quit"
    echo
    read -rp "Choose: " ch
    case "$ch" in
      1) install_self; pause ;;
      2) manager_ui ;;
      q|Q) exit 0 ;;
      *) c_warn "Invalid option"; pause ;;
    esac
  done
}

# Ensure /usr/local/bin exists
[ -d "/usr/local/bin" ] || { c_info "Creating /usr/local/bin ..."; sudo mkdir -p /usr/local/bin; }

# Auto-install snapd if missing, then open manager
if ! is_snap_installed; then
  install_snapd_flow
fi

# Start installer main menu (user can also jump straight to manager)
installer_ui
