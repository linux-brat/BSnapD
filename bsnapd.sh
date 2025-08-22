#!/usr/bin/env bash
# bsnapd.sh
# Project: BSnapD - https://github.com/linux-brat/BSnapD/
# Version: 1.4.0
# Features:
# - Always shows Installer landing first
# - Themes: --theme=dark|light|mono|hi-contrast (default: dark)
# - Accessible layout that adapts to terminal width
# - Snap Manager: list installed snaps, search and install, remove with confirm
# - Service Manager: colored status badges, robust enabled/disabled logic
# - Auto-install snapd if missing when opening managers
# - Installs/updates `bsnap` launcher to /usr/local/bin
# - --help usage and unknown-arg handling
# - Auto-update hook ready (optional, commented section marked AUTO_UPDATE)

set -euo pipefail

APP_NAME="bsnap"
INSTALL_PATH="/usr/local/bin/${APP_NAME}"
REPO_URL="https://github.com/linux-brat/BSnapD/"
REPO_RAW="https://raw.githubusercontent.com/linux-brat/BSnapD/main/bsnapd.sh"
SELF_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"

SERVICES=("snapd.socket" "snapd.apparmor.service")
ASCII_LOGO=$'██████╗░░██████╗███╗░░██╗░█████╗░██████╗░██████╗░\n██╔══██╗██╔════╝████╗░██║██╔══██╗██╔══██╗██╔══██╗\n██████╦╝╚█████╗░██╔██╗██║███████║██████╔╝██║░░██║\n██╔══██╗░╚═══██╗██║╚████║██╔══██║██╔═══╝░██║░░██║\n██████╦╝██████╔╝██║░╚███║██║░░██║██║░░░░░██████╔╝\n╚═════╝░╚═════╝░╚═╝░░╚══╝╚═╝░░╚═╝╚═╝░░░░░╚═════╝░'

# ---------------------- Theming ----------------------
THEME="dark"
for arg in "$@"; do
  case "$arg" in
    --theme=*) THEME="${arg#*=}";;
  esac
done

# Fallback if NO_COLOR set or dumb terminal
if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-dumb}" = "dumb" ]; then THEME="mono"; fi

# Define palette by theme
case "$THEME" in
  dark)
    BOLD="\033[1m"; NC="\033[0m"
    C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_INFO="\033[36m"; C_HEAD="\033[38;5;81m"
    BADGE_GREEN_BG="\033[48;5;22m\033[38;5;255m"
    BADGE_RED_BG="\033[48;5;52m\033[38;5;255m"
    BADGE_YELLOW_BG="\033[48;5;178m\033[38;5;0m"
    ;;
  light)
    BOLD="\033[1m"; NC="\033[0m"
    C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_INFO="\033[34m"; C_HEAD="\033[35m"
    BADGE_GREEN_BG="\033[48;5;120m\033[38;5;0m"
    BADGE_RED_BG="\033[48;5;210m\033[38;5;0m"
    BADGE_YELLOW_BG="\033[48;5;229m\033[38;5;0m"
    ;;
  hi-contrast)
    BOLD="\033[1m"; NC="\033[0m"
    C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"; C_INFO="\033[1;36m"; C_HEAD="\033[1;37m"
    BADGE_GREEN_BG="\033[1;42m\033[30m"
    BADGE_RED_BG="\033[1;41m\033[97m"
    BADGE_YELLOW_BG="\033[1;43m\033[30m"
    ;;
  mono|*)
    BOLD=""; NC=""
    C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_HEAD=""
    BADGE_GREEN_BG=""; BADGE_RED_BG=""; BADGE_YELLOW_BG=""
    ;;
esac
BADGE_OFF="\033[0m"
border="============================================================"

c_bold(){ printf "${BOLD}%s${NC}\n" "$*"; }
c_head(){ printf "${C_HEAD}%s${NC}\n" "$*"; }
c_ok(){ printf "${C_OK}%s${NC}\n" "$*"; }
c_warn(){ printf "${C_WARN}%s${NC}\n" "$*"; }
c_err(){ printf "${C_ERR}%s${NC}\n" "$*"; }
c_info(){ printf "${C_INFO}%s${NC}\n" "$*"; }
pause(){ read -rp "Press Enter to continue..." _; }

# layout adaptation
term_cols(){ tput cols 2>/dev/null || echo 80; }
compact_status=0
[ "$(term_cols)" -lt 80 ] && compact_status=1

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

# ---------------------- Helpers ----------------------
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
  c_head "$border"; c_head "  Snapd Installation"; c_head "$border"
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
  c_ok "Snapd installation completed."
  pause
}

# ---------------------- Snap Manager ----------------------
snap_manager(){
  # Ensure snapd exists
  if ! is_snap_installed; then
    c_warn "snap not detected. Installing now..."
    install_snapd_flow
  fi

  while true; do
    clear
    c_bold "$ASCII_LOGO"; echo
    c_head "$border"; c_head "  BSnapD • Snap Manager"; c_head "$border"
    echo "  1) List installed snaps"
    echo "  2) Search and install snaps"
    echo "  3) Remove a snap"
    echo "  b) Back"
    echo
    read -rp "Choose: " m
    case "$m" in
      1) snap_list_installed ;;
      2) snap_search_install ;;
      3) snap_remove ;;
      b|B) return ;;
      *) c_warn "Invalid option"; pause ;;
    esac
  done
}

snap_list_installed(){
  clear
  c_head "$border"; c_head "  Installed Snaps"; c_head "$border"
  if ! command -v snap >/dev/null 2>&1; then c_err "snap command not available"; pause; return; fi
  # Show name, version, revision, tracking, publisher
  if snap list >/dev/null 2>&1; then
    # Header
    printf "%-28s %-16s %-10s %-12s %-20s\n" "Name" "Version" "Rev" "Tracking" "Publisher"
    echo "------------------------------------------------------------------------------------------------------"
    snap list | awk 'NR>1{printf "%-28s %-16s %-10s %-12s %-20s\n",$1,$2,$3,$5,$4}'
  else
    c_warn "No snaps installed or snapd not ready."
  fi
  echo; pause
}

snap_search_install(){
  while true; do
    clear
    c_head "$border"; c_head "  Search & Install"; c_head "$border"
    echo "Type a search term (e.g., 'vlc', 'spotify') or 'b' to go back."
    echo
    read -rp "Search: " q
    case "$q" in
      b|B|"" ) return ;;
    esac

    clear
    c_head "$border"; c_head "  Results for: $q"; c_head "$border"
    # Search snaps (limit lines for readability)
    if snap find "$q" >/tmp/bsnapd_find.$$ 2>/dev/null; then
      # Print table with index
      idx=0
      printf "%-4s %-30s %-18s %-12s %-25s\n" "#" "Name" "Version" "Channel" "Publisher"
      echo "------------------------------------------------------------------------------------------------------------"
      awk 'NR>1 && $1!~/^-/ {printf "%-30s %-18s %-12s %-25s\n",$1,$2,$4,$3}' /tmp/bsnapd_find.$$ | nl -w2 -s'  ' | head -n 25
      echo
      echo "Select a number to install, or 's' to search again, or 'b' to go back."
      read -rp "Choice: " pick
      case "$pick" in
        b|B) rm -f /tmp/bsnapd_find.$$; return ;;
        s|S) continue ;;
        '' ) continue ;;
        * )
          if [[ "$pick" =~ ^[0-9]+$ ]]; then
            # Extract the chosen name
            name=$(awk 'NR>1 && $1!~/^-/ {print $1}' /tmp/bsnapd_find.$$ | sed -n "${pick}p")
            if [ -z "${name:-}" ]; then
              c_warn "Invalid selection"; pause
            else
              snap_install_flow "$name"
            fi
          else
            c_warn "Invalid input"; pause
          fi
          ;;
      esac
      rm -f /tmp/bsnapd_find.$$
    else
      c_warn "Search failed or no results."
      pause
    fi
  done
}

snap_install_flow(){
  local name="$1"
  clear
  c_head "$border"; c_head "  Install: $name"; c_head "$border"
  echo "Options:"
  echo "  1) Install (stable)"
  echo "  2) Install (candidate)"
  echo "  3) Install (beta)"
  echo "  4) Install (edge)"
  echo "  c) Cancel"
  echo
  read -rp "Choose: " ch
  local channel="stable"
  case "$ch" in
    1) channel="stable" ;;
    2) channel="candidate" ;;
    3) channel="beta" ;;
    4) channel="edge" ;;
    c|C) return ;;
    *) c_warn "Invalid option"; pause; return ;;
  esac
  echo
  read -rp "Use classic confinement if required? (y/N): " cl
  local classic_flag=""
  [[ "${cl,,}" == "y" ]] && classic_flag="--classic"
  echo
  c_info "Installing: snap install $name --channel=$channel $classic_flag"
  if sudo snap install "$name" --channel="$channel" $classic_flag; then
    c_ok "Installed $name ($channel)."
  else
    c_err "Failed to install $name."
  fi
  echo; pause
}

snap_remove(){
  clear
  c_head "$border"; c_head "  Remove a Snap"; c_head "$border"
  if ! snap list >/dev/null 2>&1; then c_warn "No snaps installed."; pause; return; fi
  snap list | awk 'NR>1{print NR-1") "$1"  ("$2")"}'
  echo
  read -rp "Enter number to remove (or 'b' to back): " n
  case "$n" in
    b|B) return ;;
    * )
      if [[ "$n" =~ ^[0-9]+$ ]]; then
        local name
        name=$(snap list | awk 'NR>1{print $1}' | sed -n "${n}p")
        if [ -z "${name:-}" ]; then c_warn "Invalid selection"; pause; return; fi
        read -rp "Confirm remove '$name'? (y/N): " ans
        if [[ "${ans,,}" == "y" ]]; then
          if sudo snap remove "$name"; then c_ok "Removed $name."; else c_err "Failed to remove $name."; fi
        else
          c_warn "Cancelled."
        fi
      else
        c_warn "Invalid input."
      fi
      ;;
  esac
  echo; pause
}

# ---------------------- Service Manager ----------------------
service_menu(){
  local svc="$1"
  while true; do
    clear
    c_bold "$ASCII_LOGO"; echo
    c_head "$border"; c_head "  Service: $svc"; c_head "$border"
    local a e; a=$(active_status "$svc"); e=$(enabled_status "$svc")
    if [ $compact_status -eq 1 ]; then
      printf "  %s  /  %s\n" "$(badge_active "$a")" "$(badge_enabled "$e")"
    else
      printf "  Status: %s  |  %s\n" "$(badge_active "$a")" "$(badge_enabled "$e")"
    fi
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
    c_head "$border"; c_head "  BSnapD • Snap Services Manager"; c_head "$border"
    if ! is_snap_installed; then
      c_warn "snap is NOT installed. Installing now..."
      install_snapd_flow
    fi
    c_ok "snap is installed."
    echo
    echo "Services Status:"
    for i in "${!SERVICES[@]}"; do
      s="${SERVICES[$i]}"; a=$(active_status "$s"); e=$(enabled_status "$s")
      if [ $compact_status -eq 1 ]; then
        printf "  %d) %-24s %s %s\n" "$((i+1))" "$s" "$(badge_active "$a")" "$(badge_enabled "$e")"
      else
        printf "  %d) %-28s [ %s | %s ]\n" "$((i+1))" "$s" "$(badge_active "$a")" "$(badge_enabled "$e")"
      fi
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

# ---------------------- Installer ----------------------
install_bsnap_command(){
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
SERVICES=("snapd.socket" "snapd.apparmor.service")
BOLD="\033[1m"; NC="\033[0m"; C_OK="\033[32m"; C_WARN="\033[33m"; C_HEAD="\033[36m"
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
service_menu(){ local svc="$1"; while true; do clear; c_bold "$ASCII_LOGO"; echo; c_bold "$border"; c_bold "  Service: $svc"; c_bold "$border"; local a e; a=$(active_status "$svc"); e=$(enabled_status "$svc"); printf "  Status: %s  |  %s\n" "$(badge_active "$a")" "$(badge_enabled "$e")"; echo; echo "  1) Turn ON"; echo "  2) Turn OFF"; echo "  b) Back"; echo; read -rp "Choose: " act; case "$act" in 1) sudo systemctl enable "$svc" >/dev/null 2>&1; sudo systemctl start "$svc" || true; sudo systemctl daemon-reload || true; c_ok "[$svc] ON"; pause ;; 2) systemctl is-active --quiet "$svc" && sudo systemctl stop "$svc" || true; systemctl is-enabled --quiet "$svc" && sudo systemctl disable "$svc" >/dev/null 2>&1 || true; sudo systemctl daemon-reload || true; c_ok "[$svc] OFF"; pause ;; b|B) return ;; *) echo "Invalid option"; pause ;; esac; done; }
manager_ui(){ while true; do clear; c_bold "$ASCII_LOGO"; echo; c_bold "$border"; c_bold "  BSnapD • Snap Services Manager"; c_bold "$border"; if ! is_snap_installed; then echo "snap is NOT installed. Run bsnapd.sh installer."; echo "q) Quit"; read -rp "Choose: " ch; case "$ch" in q|Q) exit 0 ;; *) continue ;; esac; fi; c_ok "snap is installed."; echo; echo "Services Status:"; for i in "${!SERVICES[@]}"; do s="${SERVICES[$i]}"; a=$(active_status "$s"); e=$(enabled_status "$s"); printf "  %d) %-28s [ %s | %s ]\n" "$((i+1))" "$s" "$(badge_active "$a")" "$(badge_enabled "$e")"; done; echo "  r) Refresh"; echo "  q) Quit"; echo; read -rp "Select a service number, or option: " choice; case "$choice" in q|Q) exit 0 ;; r|R) continue ;; * ) if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#SERVICES[@]} )); then service_menu "${SERVICES[$((choice-1))]}"; else echo "Invalid selection"; pause; fi ;; esac; done; }
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
    c_head "$border"
    c_head "  BSnapD • Installer"
    c_head "$border"
    echo "  Repo: $REPO_URL"
    echo "  Theme: $THEME"
    echo
    echo "  1) Install/Update bsnap command"
    echo "  2) Manage snap services"
    echo "  3) Snap manager (list/search/install/remove)"
    echo "  q) Quit"
    echo
    read -rp "Choose: " ch
    case "$ch" in
      1) install_bsnap_command; pause ;;
      2) manager_ui ;;
      3) snap_manager ;;
      q|Q) exit 0 ;;
      *) c_warn "Invalid option"; pause ;;
    esac
  done
}

# ---------------------- Help ----------------------
show_help(){
  cat <<EOF
BSnapD Installer/Manager (Theme-aware)

Usage:
  ./bsnapd.sh [--theme=dark|light|mono|hi-contrast] [--help]

Options:
  --theme=...     Choose color theme (default: dark).
  --help, -h      Show this help.

What you can do:
  - Install or update the 'bsnap' command
  - Manage snap services (snapd.socket, snapd.apparmor.service)
  - Snap Manager: list installed, search & install, remove snaps
  - Auto-installs snapd when needed
EOF
}

# ---------------------- Auto-update (optional) ----------------------
# If you want auto-update on launch, uncomment the function call in main().
auto_update_self(){
  [[ "$SELF_PATH" == "-" ]] && return 0
  local tmp; tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$REPO_RAW" -o "$tmp" || { rm -f "$tmp"; return 0; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$REPO_RAW" || { rm -f "$tmp"; return 0; }
  else
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    local lcs rcs
    lcs="$(sha256sum "$SELF_PATH" | awk '{print $1}')" || true
    rcs="$(sha256sum "$tmp" | awk '{print $1}')" || true
    if [ "$lcs" != "$rcs" ]; then
      c_info "Updating BSnapD from GitHub..."
      chmod +x "$tmp"
      if sudo mv "$tmp" "$SELF_PATH"; then
        sudo chmod +x "$SELF_PATH"
        c_ok "Update complete. Relaunching..."
        exec "$SELF_PATH" "$@"
      else
        c_err "Auto-update failed; continuing with current version."
      fi
    else
      rm -f "$tmp"
    fi
  else
    # If no sha256sum, overwrite blindly
    chmod +x "$tmp"
    sudo mv "$tmp" "$SELF_PATH" || true
    sudo chmod +x "$SELF_PATH" || true
  fi
}

# ---------------------- Main ----------------------
main(){
  # Parse help/unknown args
  for a in "$@"; do
    case "$a" in
      -h|--help) show_help; exit 0 ;;
      --theme=*) : ;; # already parsed
      *) c_warn "Unknown option: $a"; echo; show_help; exit 1 ;;
    esac
  done

  # Ensure /usr/local/bin exists
  [ -d "/usr/local/bin" ] || { c_info "Creating /usr/local/bin ..."; sudo mkdir -p /usr/local/bin; }

  # AUTO_UPDATE: uncomment next line to enable self-update each launch
  # auto_update_self "$@"

  # Always launch installer landing first
  installer_ui
}

main "$@"
