#!/usr/bin/env bash
# bsnapd.sh
# Project: BSnapD - https://github.com/linux-brat/BSnapD/
# Version: 1.3.0
# Features:
# - Always shows Installer landing screen first
# - Auto-update from GitHub on launch (compares checksum/version)
# - --help/-h support; unknown args print help
# - Installs/updates `bsnap` command in /usr/local/bin
# - Auto-installs snapd if missing before Manager UI
# - Colored ACTIVE/ENABLED badges, fixed enabled-state reporting

set -euo pipefail

APP_NAME="bsnap"
INSTALL_PATH="/usr/local/bin/${APP_NAME}"
REPO_RAW="https://raw.githubusercontent.com/linux-brat/BSnapD/main/bsnapd.sh"
SELF_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"

SERVICES=("snapd.socket" "snapd.apparmor.service")

ASCII_LOGO=$'██████╗░░██████╗███╗░░██╗░█████╗░██████╗░██████╗░\n██╔══██╗██╔════╝████╗░██║██╔══██╗██╔══██╗██╔══██╗\n██████╦╝╚█████╗░██╔██╗██║███████║██████╔╝██║░░██║\n██╔══██╗░╚═══██╗██║╚████║██╔══██║██╔═══╝░██║░░██║\n██████╦╝██████╔╝██║░╚███║██║░░██║██║░░░░░██████╔╝\n╚═════╝░╚═════╝░╚═╝░░╚══╝╚═╝░░╚═╝╚═╝░░░░░╚═════╝░'

# Colors and badges
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

badge_active(){ [[ "$1" == "Active" ]] && printf "${BADGE_GREEN_BG} ACTIVE ${BADGE_OFF}" || printf "${BADGE_RED_BG} INACTIVE ${BADGE_OFF}"; }
badge_enabled(){
  case "$1" in
    Enabled|enabled)   printf "${BADGE_GREEN_BG} ENABLED ${BADGE_OFF}" ;;
    Disabled|disabled) printf "${BADGE_RED_BG} DISABLED ${BADGE_OFF}" ;;
    static)            printf "${BADGE_YELLOW_BG} STATIC ${BADGE_OFF}" ;;
    indirect)          printf "${BADGE_YELLOW_BG} INDIRECT ${BADGE_OFF}" ;;
    masked)            printf "${BADGE_RED_BG} MASKED ${BADGE_OFF}" ;;
    *)                 printf "${BADGE_YELLOW_BG} $1 ${BADGE_OFF}" ;;
  esac
}

# Helpers
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

active_status(){ local s=$1; systemctl is-active --quiet "$s" && echo "Active" || echo "Inactive"; }
enabled_status(){ local s=$1; systemctl show -p UnitFileState --value "$s" 2>/dev/null || echo "unknown"; }

enable_service(){
  local s=$1
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
  if systemctl is-active --quiet "$s"; then
    sudo systemctl stop "$s" || true
    c_ok "[$s] has been stopped"
  else
    c_warn "[$s] is already OFF"
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
  c_bold "$ASCII_LOGO"; echo
  c_bold "$border"; c_bold "  Snapd Installation"; c_bold "$border"
  local mgr; mgr="$(pkg_mgr)"
  c_info "Detected package manager: $mgr"
  case "$mgr" in
    apt)    c_info "Updating apt and installing snapd + apparmor..."; sudo apt-get update -y; sudo apt-get install -y snapd apparmor || true ;;
    dnf)    c_info "Installing snapd..."; sudo dnf install -y snapd || true ;;
    yum)    c_info "Installing snapd..."; sudo yum install -y epel-release || true; sudo yum install -y snapd || true ;;
    zypper) c_info "Installing snapd..."; sudo zypper --non-interactive install snapd || true ;;
    pacman) c_info "Installing snapd..."; sudo pacman -Syu --noconfirm snapd || { c_err "Failed via pacman. Enable repos or use AUR."; pause; return 1; } ;;
    *)      c_err "Unsupported package manager. Install snapd manually."; pause; return 1 ;;
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
    c_bold "$ASCII_LOGO"; echo
    c_bold "$border"; c_bold "  Service: $svc"; c_bold "$border"
    local a e; a=$(active_status "$svc"); e=$(enabled_status "$svc")
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
    c_bold "$ASCII_LOGO"; echo
    c_bold "$border"; c_bold "  BSnapD • Snap Services Manager"; c_bold "$border"

    if ! is_snap_installed; then
      c_warn "snap is NOT installed. Installing now..."
      install_snapd_flow
    fi
    c_ok "snap is installed."

    echo
    echo "Services Status:"
    for i in "${!SERVICES[@]}"; do
      s="${SERVICES[$i]}"; a=$(active_status "$s"); e=$(enabled_status "$s")
      printf "  %d) %-28s [ %s | %s ]\n" "$((i+1))" "$s" "$(badge_active "$a")" "$(badge_enabled "$e")"
    done
    echo "  r) Refresh"
    echo "  q) Quit"
    echo
    read -rp "Select a service number, or option: " choice
    case "$choice" in
      q|Q) return 0 ;;
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

install_bsnap_command(){
  # Slim runtime that just opens the manager (snap install prompt inside)
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
SERVICES=("snapd.socket" "snapd.apparmor.service")
BOLD="\033[1m"; NC="\033[0m"; C_OK="\033[32m"; C_WARN="\033[33m"; C_INFO="\033[36m"
BADGE_GREEN_BG="\033[48;5;22m\033[38;5;255m"; BADGE_RED_BG="\033[48;5;52m\033[38;5;255m"; BADGE_YELLOW_BG="\033[48;5;178m\033[38;5;0m"; BADGE_OFF="\033[0m"
border="============================================================"
ASCII_LOGO=$'██████╗░░██████╗███╗░░██╗░█████╗░██████╗░██████╗░\n██╔══██╗██╔════╝████╗░██║██╔══██╗██╔══██╗██╔══██╗\n██████╦╝╚█████╗░██╔██╗██║███████║██████╔╝██║░░██║\n██╔══██╗░╚═══██╗██║╚████║██╔══██║██╔═══╝░██║░░██║\n██████╦╝██████╔╝██║░╚███║██║░░██║██║░░░░░██████╔╝\n╚═════╝░╚═════╝░╚═╝░░╚══╝╚═╝░░╚═╝╚═╝░░░░░╚═════╝░'
c_bold(){ printf "${BOLD}%s${NC}\n" "$*"; }
c_ok(){ printf "${C_OK}%s${NC}\n" "$*"; }
c_warn(){ printf "${C_WARN}%s${NC}\n" "$*"; }
pause(){ read -rp "Press Enter to continue..." _; }
is_snap_installed(){ command -v snap >/dev/null 2>&1; }
active_status(){ local s=$1; systemctl is-active --quiet "$s" && echo "Active" || echo "Inactive"; }
enabled_status(){ local s=$1; systemctl show -p UnitFileState --value "$s" 2>/dev/null || echo "unknown"; }
badge_active(){ [[ "$1" == "Active" ]] && printf "${BADGE_GREEN_BG} ACTIVE ${BADGE_OFF}" || printf "${BADGE_RED_BG} INACTIVE ${BADGE_OFF}"; }
badge_enabled(){ case "$1" in Enabled|enabled) printf "${BADGE_GREEN_BG} ENABLED ${BADGE_OFF}";; Disabled|disabled) printf "${BADGE_RED_BG} DISABLED ${BADGE_OFF}";; static) printf "${BADGE_YELLOW_BG} STATIC ${BADGE_OFF}";; indirect) printf "${BADGE_YELLOW_BG} INDIRECT ${BADGE_OFF}";; masked) printf "${BADGE_RED_BG} MASKED ${BADGE_OFF}";; *) printf "${BADGE_YELLOW_BG} $1 ${BADGE_OFF}";; esac; }
enable_service(){ local s=$1; sudo systemctl unmask "$s" >/dev/null 2>&1 || true; if systemctl is-active --quiet "$s"; then c_warn "[$s] is already ON"; else sudo systemctl enable "$s" >/dev/null 2>&1 && sudo systemctl start "$s" || true; sudo systemctl daemon-reload || true; echo "[$s] turned ON"; fi; }
disable_service(){ local s=$1; systemctl is-active --quiet "$s" && sudo systemctl stop "$s" || true; if systemctl is-enabled --quiet "$s"; then sudo systemctl disable "$s" >/dev/null 2>&1 && sudo systemctl daemon-reload || true; fi; }
install_snapd_flow(){ c_bold "$border"; c_bold "  Installing snapd (run bsnapd for full installer)"; c_bold "$border"; if command -v apt-get >/dev/null 2>&1; then sudo apt-get update -y; sudo apt-get install -y snapd apparmor || true; elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y snapd || true; elif command -v yum >/dev/null 2>&1; then sudo yum install -y epel-release || true; sudo yum install -y snapd || true; elif command -v zypper >/dev/null 2>&1; then sudo zypper --non-interactive install snapd || true; elif command -v pacman >/dev/null 2>&1; then sudo pacman -Syu --noconfirm snapd || true; fi; sudo systemctl unmask snapd.socket snapd.apparmor.service >/dev/null 2>&1 || true; sudo systemctl enable --now snapd.socket || true; sudo systemctl enable --now snapd.apparmor.service || true; sudo systemctl daemon-reload || true; [ ! -e /snap ] && [ -d /var/lib/snapd/snap ] && sudo ln -s /var/lib/snapd/snap /snap || true; }
service_menu(){ local svc="$1"; while true; do clear; c_bold "$ASCII_LOGO"; echo; c_bold "$border"; c_bold "  Service: $svc"; c_bold "$border"; local a e; a=$(active_status "$svc"); e=$(enabled_status "$svc"); printf "  Status: %s  |  %s\n" "$(badge_active "$a")" "$(badge_enabled "$e")"; echo; echo "  1) Turn ON"; echo "  2) Turn OFF"; echo "  b) Back"; echo; read -rp "Choose: " act; case "$act" in 1) enable_service "$svc"; pause ;; 2) disable_service "$svc"; pause ;; b|B) return ;; *) echo "Invalid option"; pause ;; esac; done; }
manager_ui(){ while true; do clear; c_bold "$ASCII_LOGO"; echo; c_bold "$border"; c_bold "  BSnapD • Snap Services Manager"; c_bold "$border"; if ! is_snap_installed; then echo "snap is NOT installed. Installing..."; install_snapd_flow; fi; c_ok "snap is installed."; echo; echo "Services Status:"; for i in "${!SERVICES[@]}"; do s="${SERVICES[$i]}"; a=$(active_status "$s"); e=$(enabled_status "$s"); printf "  %d) %-28s [ %s | %s ]\n" "$((i+1))" "$s" "$(badge_active "$a")" "$(badge_enabled "$e")"; done; echo "  r) Refresh"; echo "  q) Quit"; echo; read -rp "Select a service number, or option: " choice; case "$choice" in q|Q) exit 0 ;; r|R) continue ;; * ) if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#SERVICES[@]} )); then service_menu "${SERVICES[$((choice-1))]}"; else echo "Invalid selection"; pause; fi ;; esac; done; }
manager_ui
EOS
  sudo install -m 0755 "$tmp" "$INSTALL_PATH"; rm -f "$tmp"
  c_ok "Installed ${APP_NAME} to ${INSTALL_PATH}"
}

show_help(){
  cat <<EOF
BSnapD Installer/Manager

Usage:
  ./bsnapd.sh            Launch Installer (default)
  ./bsnapd.sh --help     Show this help
  ./bsnapd.sh -h         Show this help

What you can do:
  - Install or update the 'bsnap' command
  - Manage snapd.socket and snapd.apparmor.service
  - Auto-install snapd if it's missing
EOF
}

auto_update_self(){
  # Skip auto-update if running from stdin/pipe
  [[ "$SELF_PATH" == "-" ]] && return 0

  # Fetch remote script
  local tmp remote_ver local_ver
  tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$REPO_RAW" -o "$tmp" || return 0
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$REPO_RAW" || return 0
  else
    return 0
  fi

  # Extract versions
  remote_ver="$(grep -m1 '^# Version:' "$tmp" | awk '{print $3}')" || remote_ver=""
  local_ver="$(grep -m1 '^# Version:' "$SELF_PATH" | awk '{print $3}')" || local_ver=""
  if [[ -z "$remote_ver" || -z "$local_ver" ]]; then
    # Fall back to checksum compare
    if command -v sha256sum >/dev/null 2>&1; then
      local lcs rcs; lcs="$(sha256sum "$SELF_PATH" | awk '{print $1}')" || true
      rcs="$(sha256sum "$tmp" | awk '{print $1}')" || true
      [[ "$lcs" == "$rcs" ]] && { rm -f "$tmp"; return 0; }
    else
      rm -f "$tmp"; return 0
    fi
  else
    # Compare versions: if remote differs, update
    [[ "$remote_ver" == "$local_ver" ]] && { rm -f "$tmp"; return 0; }
  fi

  c_info "Updating BSnapD from GitHub (local $local_ver -> remote $remote_ver)..."
  # Preserve executable bit and replace atomically
  chmod +x "$tmp"
  if sudo mv "$tmp" "$SELF_PATH"; then
    sudo chmod +x "$SELF_PATH"
    c_ok "Update complete. Relaunching..."
    exec "$SELF_PATH" "$@"
  else
    c_err "Update failed; continuing with current version."
    rm -f "$tmp"
  fi
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
      1) install_bsnap_command; pause ;;
      2) manager_ui ;;
      q|Q) exit 0 ;;
      *) c_warn "Invalid option"; pause ;;
    esac
  done
}

main(){
  # Help and invalid args handling
  if [[ $# -gt 0 ]]; then
    case "${1:-}" in
      -h|--help) show_help; exit 0 ;;
      *) c_warn "Unknown option: $1"; echo; show_help; exit 1 ;;
    esac
  fi

  # Ensure /usr/local/bin exists for bsnap installation
  [ -d "/usr/local/bin" ] || { c_info "Creating /usr/local/bin ..."; sudo mkdir -p /usr/local/bin; }

  # Auto-update
  auto_update_self "$@"

  # Always show installer landing screen first
  installer_ui
}

main "$@"
