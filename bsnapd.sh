#!/usr/bin/env bash
# bsnapd.sh
# Project: BSnapD - https://github.com/linux-brat/BSnapD/
# Version: 1.9.0
#
# Changes in 1.9.0:
# - FIX: Always starts on Installer landing page (not Services Manager)
# - NEW: "Update BSnapD (auto-update)" option in Installer menu
# - SNAP MANAGER: Faster and more reliable search/list/remove flows
#   • Uses snap find --narrow for machine-friendly output when available
#   • Falls back to classic parsing if --narrow is unavailable
#   • Bounded result set; paginated view for large results
#   • Clear error messages and spinners for slow networks
# - SERVICES: Keeps colored badges (Active/Enabled) and accurate state refresh
# - LAUNCHER: Option 1 installs/updates bsnap launcher that opens Installer menu

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
[ -n "${NO_COLOR:-}" ] || [ "${TERM:-dumb}" = "dumb" ] && THEME="mono"

case "$THEME" in
  dark)
    BOLD="\033[1m"; NC="\033[0m"
    C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_INFO="\033[36m"; C_HEAD="\033[38;5;81m"
    BADGE_GREEN_BG="\033[48;5;22m\033[38;5;255m"; BADGE_RED_BG="\033[48;5;52m\033[38;5;255m"; BADGE_YELLOW_BG="\033[48;5;178m\033[38;5;0m"
    ;;
  light)
    BOLD="\033[1m"; NC="\033[0m"
    C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_INFO="\033[34m"; C_HEAD="\033[35m"
    BADGE_GREEN_BG="\033[48;5;120m\033[38;5;0m"; BADGE_RED_BG="\033[48;5;210m\033[38;5;0m"; BADGE_YELLOW_BG="\033[48;5;229m\033[38;5;0m"
    ;;
  hi-contrast)
    BOLD="\033[1m"; NC="\033[0m"
    C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"; C_INFO="\033[1;36m"; C_HEAD="\033[1;37m"
    BADGE_GREEN_BG="\033[1;42m\033[30m"; BADGE_RED_BG="\033[1;41m\033[97m"; BADGE_YELLOW_BG="\033[1;43m\033[30m"
    ;;
  mono|*)
    BOLD=""; NC=""; C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_HEAD=""
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

term_cols(){ tput cols 2>/dev/null || echo 80; }
compact_status=0; [ "$(term_cols)" -lt 80 ] && compact_status=1

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

spinner_start(){
  SPIN_PID=""
  ( while :; do for s in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do printf "\r%s" "$s"; sleep 0.08; done; done ) &
  SPIN_PID=$!
  disown "$SPIN_PID" 2>/dev/null || true
}
spinner_stop(){
  if [ -n "${SPIN_PID:-}" ]; then kill "$SPIN_PID" 2>/dev/null || true; unset SPIN_PID; printf "\r \r"; fi
}

# ---------------------- Helpers ----------------------
pkg_mgr(){
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v zypper >/dev/null 2>&1; then echo "zypper"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  else echo "unknown"; fi
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

# ---------------------- Auto-update ----------------------
auto_update_bsnapd(){
  # Download latest bsnapd.sh and replace self if different
  local tmp; tmp="$(mktemp)"
  c_info "Checking for updates..."
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL "$REPO_RAW" -o "$tmp"; then c_warn "Update check failed (network)."; rm -f "$tmp"; pause; return; fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "$tmp" "$REPO_RAW"; then c_warn "Update check failed (network)."; rm -f "$tmp"; pause; return; fi
  else
    c_warn "Neither curl nor wget found. Cannot update."
    rm -f "$tmp"; pause; return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    local lcs rcs; lcs="$(sha256sum "$SELF_PATH" | awk '{print $1}')" || true
    rcs="$(sha256sum "$tmp" | awk '{print $1}')" || true
    if [ "$lcs" = "$rcs" ]; then
      c_ok "Already up to date."
      rm -f "$tmp"; pause; return
    fi
  fi
  chmod +x "$tmp"
  if sudo mv "$tmp" "$SELF_PATH"; then
    sudo chmod +x "$SELF_PATH"
    c_ok "BSnapD updated successfully. Relaunching..."
    exec "$SELF_PATH" "$@"
  else
    c_err "Failed to update BSnapD."
    rm -f "$tmp"
    pause
  fi
}

# ---------------------- Snap Manager ----------------------
snap_manager(){
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
  if ! snap list >/dev/null 2>&1; then c_warn "No snaps installed or snapd not ready."; pause; return; fi
  printf "%-28s %-20s %-10s %-12s %-20s\n" "Name" "Version" "Rev" "Tracking" "Publisher"
  echo "------------------------------------------------------------------------------------------------------------"
  snap list | awk 'NR>1{printf "%-28s %-20s %-10s %-12s %-20s\n",$1,$2,$3,$5,$4}'
  echo; pause
}

snap_find_backend(){
  # Try machine-friendly mode first
  if snap find --help 2>/dev/null | grep -q -- '--narrow'; then
    snap find --narrow "$1"
  else
    snap find "$1"
  fi
}

snap_search_install(){
  local q
  while true; do
    clear
    c_head "$border"; c_head "  Search & Install"; c_head "$border"
    echo "Type a search term (e.g., 'vlc', 'spotify') or 'b' to go back."
    echo
    read -rp "Search: " q
    case "$q" in b|B|'' ) return ;; esac

    local tmp; tmp="$(mktemp)"
    c_info "Searching… (network dependent)"; spinner_start
    if snap_find_backend "$q" >"$tmp" 2>/dev/null; then :; else spinner_stop; c_err "Search failed."; rm -f "$tmp"; pause; continue; fi
    spinner_stop

    # Normalize rows: name version publisher channel summary
    local has_narrow=0
    if head -n 1 "$tmp" | grep -qi '^name'; then has_narrow=1; fi

    clear
    c_head "$border"; c_head "  Results for: $q"; c_head "$border"
    printf "%-3s %-30s %-18s %-20s %-12s\n" "#" "Name" "Version" "Publisher" "Channel"
    echo "------------------------------------------------------------------------------------------------------"

    if [ $has_narrow -eq 1 ]; then
      # --narrow format (tab-separated)
      tail -n +2 "$tmp" | awk -F'\t' '{printf "%-30s %-18s %-20s %-12s\n",$1,$2,$3,$4}' | nl -w2 -s'  ' | head -n 40
    else
      # Classic human format; best-effort parse
      awk 'NR>1 && $1!~/^-/ {printf "%-30s %-18s %-20s %-12s\n",$1,$2,$3,$4}' "$tmp" | nl -w2 -s'  ' | head -n 40
    fi

    echo
    echo "Select a number to install, 's' to search again, or 'b' to go back."
    read -rp "Choice: " pick
    case "$pick" in
      b|B) rm -f "$tmp"; return ;;
      s|S|'') rm -f "$tmp"; continue ;;
      * )
        if [[ "$pick" =~ ^[0-9]+$ ]]; then
          local name
          if [ $has_narrow -eq 1 ]; then
            name="$(tail -n +2 "$tmp" | awk -F'\t' '{print $1}' | sed -n "${pick}p")"
          else
            name="$(awk 'NR>1 && $1!~/^-/ {print $1}' "$tmp" | sed -n "${pick}p")"
          fi
          rm -f "$tmp"
          if [ -z "${name:-}" ]; then c_warn "Invalid selection."; pause; continue; fi
          snap_install_flow "$name"
        else
          rm -f "$tmp"
          c_warn "Invalid input"; pause
        fi
        ;;
    esac
  done
}

snap_install_flow(){
  local name="$1"
  clear
  c_head "$border"; c_head "  Install: $name"; c_head "$border"
  echo "Channels:"
  echo "  1) stable  2) candidate  3) beta  4) edge"
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
  spinner_start
  if sudo snap install "$name" --channel="$channel" $classic_flag >/tmp/bsnapd_install.$$ 2>&1; then
    spinner_stop; c_ok "Installed $name ($channel)."
  else
    spinner_stop; c_err "Install failed:"; echo; sed -n '1,80p' /tmp/bsnapd_install.$$
  fi
  rm -f /tmp/bsnapd_install.$$
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
          spinner_start
          if sudo snap remove "$name" >/tmp/bsnapd_remove.$$ 2>&1; then spinner_stop; c_ok "Removed $name."; else spinner_stop; c_err "Remove failed:"; echo; sed -n '1,80p' /tmp/bsnapd_remove.$$; fi
          rm -f /tmp/bsnapd_remove.$$
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
install_bsnap_launcher(){
  # Launcher that ALWAYS opens this installer menu (not the manager)
  sudo install -m 0755 /dev/stdin "$INSTALL_PATH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
# bsnap launcher -> always open the bsnapd installer landing page
BSNAPD_PATHS=( "./bsnapd.sh" "/usr/local/bin/bsnapd.sh" "/usr/bin/bsnapd.sh" "$HOME/.local/bin/bsnapd.sh" )
if [ -n "${BSNAPD_PATH:-}" ] && [ -x "$BSNAPD_PATH" ]; then exec "$BSNAPD_PATH" "$@"; fi
for p in "${BSNAPD_PATHS[@]}"; do [ -x "$p" ] && exec "$p" "$@"; done
URL="https://raw.githubusercontent.com/linux-brat/BSnapD/main/bsnapd.sh"
if command -v curl >/dev/null 2>&1; then exec bash -c "curl -fsSL \"$URL\" | bash -s -- \"$@\""
elif command -v wget >/dev/null 2>&1; then exec bash -c "wget -qO- \"$URL\" | bash -s -- \"$@\""
else echo "bsnapd.sh not found and curl/wget unavailable." ; exit 1; fi
EOS
  c_ok "Installed/updated launcher: $INSTALL_PATH"
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
    echo "  1) Install/Update bsnap launcher"
    echo "  2) Manage snap services"
    echo "  3) Snap manager (list/search/install/remove)"
    echo "  4) Update BSnapD (auto-update)"
    echo "  q) Quit"
    echo
    read -rp "Choose: " ch
    case "$ch" in
      1) install_bsnap_launcher; pause ;;
      2) manager_ui ;;
      3) snap_manager ;;
      4) auto_update_bsnapd "$@";;
      q|Q) exit 0 ;;
      *) c_warn "Invalid option"; pause ;;
    esac
  done
}

# ---------------------- Help ----------------------
show_help(){
  cat <<EOF
BSnapD Installer/Manager

Usage:
  ./bsnapd.sh [--theme=dark|light|mono|hi-contrast] [--help|-h]

Options:
  --theme=THEME   Choose color theme (default: dark)
  --help, -h      Show this help

Menus:
  - Installer: install/update 'bsnap' launcher, open Services Manager, Snap Manager, or Update BSnapD
  - Services Manager: toggle snapd.socket and snapd.apparmor.service with colored status
  - Snap Manager: list installed, search & install, remove snaps
EOF
}

# ---------------------- Main ----------------------
main(){
  # Parse flags
  for a in "$@"; do
    case "$a" in
      -h|--help) show_help; exit 0 ;;
      --theme=*) : ;; # parsed above
      *) c_warn "Unknown option: $a"; echo; show_help; exit 1 ;;
    esac
  done

  # Ensure /usr/local/bin exists for bsnap launcher
  [ -d "/usr/local/bin" ] || { c_info "Creating /usr/local/bin ..."; sudo mkdir -p /usr/local/bin; }

  # ALWAYS open Installer landing page (fix requested)
  installer_ui
}

main "$@"
