#!/usr/bin/env bash
# bsnapd.sh
# Project: BSnapD - https://github.com/linux-brat/BSnapD/
# Purpose: Install a `bsnap` command and provide a TUI for managing snapd services.
# It checks for snapd, offers installation, and lets you enable/disable:
# - snapd.socket
# - snapd.apparmor.service
# Displays ASCII logo on installer and manager pages.

set -euo pipefail

APP_NAME="bsnap"
INSTALL_PATH="/usr/local/bin/${APP_NAME}"
SERVICES=("snapd.socket" "snapd.apparmor.service")

ASCII_LOGO=$'██████╗░░██████╗███╗░░██╗░█████╗░██████╗░██████╗░\n██╔══██╗██╔════╝████╗░██║██╔══██╗██╔══██╗██╔══██╗\n██████╦╝╚█████╗░██╔██╗██║███████║██████╔╝██║░░██║\n██╔══██╗░╚═══██╗██║╚████║██╔══██║██╔═══╝░██║░░██║\n██████╦╝██████╔╝██║░╚███║██║░░██║██║░░░░░██████╔╝\n╚═════╝░╚═════╝░╚═╝░░╚══╝╚═╝░░╚═╝╚═╝░░░░░╚═════╝░'

# ------------- Styling helpers -------------
c_info() { printf "\033[36m%s\033[0m\n" "$*"; }
c_ok()   { printf "\033[32m%s\033[0m\n" "$*"; }
c_warn() { printf "\033[33m%s\033[0m\n" "$*"; }
c_err()  { printf "\033[31m%s\033[0m\n" "$*"; }
c_bold() { printf "\033[1m%s\033[0m\n"   "$*"; }
border="============================================================"
pause() { read -rp "Press Enter to continue..." _; }

# ------------- Common helpers -------------
pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v zypper >/dev/null 2>&1; then echo "zypper"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  else echo "unknown"
  fi
}

is_snap_installed() { command -v snap >/dev/null 2>&1; }

active_status() {
  local svc=$1
  if systemctl is-active --quiet "$svc"; then echo "Active"; else echo "Inactive"; fi
}
enabled_status() {
  local svc=$1
  if systemctl is-enabled --quiet "$svc"; then echo "Enabled"; else echo "Disabled"; fi
}

enable_service() {
  local svc=$1
  if systemctl is-active --quiet "$svc"; then
    c_warn "[$svc] is already ON"
  else
    if sudo systemctl enable --now "$svc"; then
      c_ok "[$svc] has been turned ON"
    else
      c_err "Failed to enable [$svc]"
    fi
  fi
}

disable_service() {
  local svc=$1
  if ! systemctl is-active --quiet "$svc"; then
    c_warn "[$svc] is already OFF"
  else
    if sudo systemctl disable --now "$svc"; then
      c_ok "[$svc] has been turned OFF"
    else
      c_err "Failed to disable [$svc]"
    fi
  fi
}

install_snapd_flow() {
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
  sudo systemctl enable --now snapd.socket || true
  sudo systemctl enable --now snapd.apparmor.service || true

  if [ ! -e /snap ] && [ -d /var/lib/snapd/snap ]; then
    c_info "Creating /snap symlink -> /var/lib/snapd/snap ..."
    sudo ln -s /var/lib/snapd/snap /snap || true
  fi

  c_ok "Snapd installation step completed."
  pause
}

service_menu() {
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
    echo "  Status: Active=$a  Enabled=$e"
    echo
    echo "  1) Turn ON (enable --now)"
    echo "  2) Turn OFF (disable --now)"
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

manager_ui() {
  while true; do
    clear
    c_bold "$ASCII_LOGO"
    echo
    c_bold "$border"
    c_bold "  BSnapD • Snap Services Manager"
    c_bold "$border"

    if ! is_snap_installed; then
      c_warn "snap is NOT installed."
      echo "  1) Install snapd now"
      echo "  q) Quit"
      read -rp "Choose: " ch
      case "$ch" in
        1) install_snapd_flow ;;
        q|Q) exit 0 ;;
        *) c_warn "Invalid option"; pause ;;
      esac
      continue
    else
      c_ok "snap is installed."
    fi

    echo
    echo "Services Status:"
    for i in "${!SERVICES[@]}"; do
      s="${SERVICES[$i]}"
      a=$(active_status "$s")
      e=$(enabled_status "$s")
      printf "  %d) %-28s [Active: %-8s | Enabled: %-8s]\n" "$((i+1))" "$s" "$a" "$e"
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

install_self() {
  # Generate the runtime bsnap script content (same manager UI, no installer)
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

SERVICES=("snapd.socket" "snapd.apparmor.service")
ASCII_LOGO=$'██████╗░░██████╗███╗░░██╗░█████╗░██████╗░██████╗░\n██╔══██╗██╔════╝████╗░██║██╔══██╗██╔══██╗██╔══██╗\n██████╦╝╚█████╗░██╔██╗██║███████║██████╔╝██║░░██║\n██╔══██╗░╚═══██╗██║╚████║██╔══██║██╔═══╝░██║░░██║\n██████╦╝██████╔╝██║░╚███║██║░░██║██║░░░░░██████╔╝\n╚═════╝░╚═════╝░╚═╝░░╚══╝╚═╝░░╚═╝╚═╝░░░░░╚═════╝░'

c_ok()   { printf "\033[32m%s\033[0m\n" "$*"; }
c_warn() { printf "\033[33m%s\033[0m\n" "$*"; }
c_bold() { printf "\033[1m%s\033[0m\n"   "$*"; }
border="============================================================"
pause() { read -rp "Press Enter to continue..." _; }

is_snap_installed() { command -v snap >/dev/null 2>&1; }
active_status() { local s=$1; systemctl is-active --quiet "$s" && echo "Active" || echo "Inactive"; }
enabled_status() { local s=$1; systemctl is-enabled --quiet "$s" && echo "Enabled" || echo "Disabled"; }

enable_service() {
  local s=$1
  if systemctl is-active --quiet "$s"; then
    c_warn "[$s] is already ON"
  else
    if sudo systemctl enable --now "$s"; then
      c_ok "[$s] has been turned ON"
    else
      echo "Failed to enable [$s]"
    fi
  fi
}
disable_service() {
  local s=$1
  if ! systemctl is-active --quiet "$s"; then
    c_warn "[$s] is already OFF"
  else
    if sudo systemctl disable --now "$s"; then
      c_ok "[$s] has been turned OFF"
    else
      echo "Failed to disable [$s]"
    fi
  fi
}

service_menu() {
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
    echo "  Status: Active=$a  Enabled=$e"
    echo
    echo "  1) Turn ON (enable --now)"
    echo "  2) Turn OFF (disable --now)"
    echo "  b) Back"
    echo
    read -rp "Choose: " act
    case "$act" in
      1) enable_service "$svc"; pause ;;
      2) disable_service "$svc"; pause ;;
      b|B) return ;;
      *) echo "Invalid option"; pause ;;
    esac
  done
}

manager_ui() {
  while true; do
    clear
    c_bold "$ASCII_LOGO"
    echo
    c_bold "$border"
    c_bold "  BSnapD • Snap Services Manager"
    c_bold "$border"

    if ! is_snap_installed; then
      c_warn "snap is NOT installed. Use bsnapd.sh installer to set up snapd."
      echo "  q) Quit"
      read -rp "Choose: " ch
      case "$ch" in q|Q) exit 0 ;; *) continue ;; esac
    fi

    echo
    echo "Services Status:"
    for i in "${!SERVICES[@]}"; do
      s="${SERVICES[$i]}"
      a=$(active_status "$s")
      e=$(enabled_status "$s")
      printf "  %d) %-28s [Active: %-8s | Enabled: %-8s]\n" "$((i+1))" "$s" "$a" "$e"
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
          echo "Invalid selection"; pause
        fi
        ;;
    esac
  done
}

manager_ui
EOS

  sudo install -m 0755 "$tmp" "$INSTALL_PATH"
  rm -f "$tmp"
  c_ok "Installed ${APP_NAME} to ${INSTALL_PATH}"
  if ! command -v "$APP_NAME" >/dev/null 2>&1; then
    c_warn "Note: $INSTALL_PATH may not be in PATH for current shell."
    echo "Add to PATH or open a new shell."
  fi
}

installer_ui() {
  while true; do
    clear
    c_bold "$ASCII_LOGO"
    echo
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

# Start installer UI
installer_ui
