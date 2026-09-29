#!/usr/bin/env bash
#
# setup-asusctl.sh
#
# Configuración de asusctl / asusd / ROG Control Center para hardware ASUS.
# Este componente es independiente de setup-fedora-plasma.sh.
#
# Uso:
#   chmod +x setup-asusctl.sh
#   ./setup-asusctl.sh
#
# Requiere un usuario normal con sudo. No ejecutar como root.

set -uo pipefail

COLOR_RESET="\e[0m"
COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_BLUE="\e[34m"

log_info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_ok()   { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_err()  { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"; }
log_step() { echo -e "\n${COLOR_BLUE}==>${COLOR_RESET} \e[1m$*${COLOR_RESET}"; }

ask_yes_no() {
    local prompt="$1"
    local answer
    while true; do
        read -rp "$(echo -e "${COLOR_YELLOW}?${COLOR_RESET} ${prompt} [s/n]: ")" answer
        case "${answer,,}" in
            s|si|sí|y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "  Respondé 's' o 'n'." ;;
        esac
    done
}

require_root_privileges() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_err "No corras este script directamente como root. Ejecutalo como tu usuario normal."
        exit 1
    fi
    if ! command -v sudo &>/dev/null; then
        log_err "No se encontró 'sudo'."
        exit 1
    fi
    sudo -v
}

pkg_installed() {
    rpm -q "$1" &>/dev/null
}

main() {
    require_root_privileges

    log_step "1/3 · Detectando hardware ASUS"

    local vendor
    vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")"

    if [[ "$vendor" != *ASUS* ]]; then
        log_info "No se detectó hardware ASUS (fabricante detectado: '${vendor:-desconocido}')."
        return 0
    fi

    log_info "Hardware ASUS detectado ($vendor)"

    if ! ask_yes_no "¿Instalar herramientas ASUS Linux (asusctl + repo Terra)?"; then
        log_info "Se omiten las herramientas ASUS a pedido del usuario"
        return 0
    fi

    log_step "2/3 · Instalando asusctl y configurando servicios"

    if ! pkg_installed terra-release; then
        sudo dnf install -y --nogpgcheck \
            --repofrompath 'terra,https://repos.fyralabs.com/terra\$releasever' \
            terra-release
        log_ok "Repositorio Terra habilitado"
    else
        log_ok "Repositorio Terra ya estaba habilitado"
    fi

    sudo dnf install -y asusctl
    sudo systemctl enable --now asusd.service
    log_ok "asusctl instalado y asusd.service activo"

    if pkg_installed tuned-ppd; then
        sudo dnf swap -y tuned-ppd power-profiles-daemon --allowerasing
        log_ok "tuned-ppd reemplazado por power-profiles-daemon"
    fi
    sudo systemctl enable --now power-profiles-daemon.service

    if ask_yes_no "¿Instalar también ROG Control Center (GUI para asusctl)?"; then
        sudo dnf install -y asusctl-rog-gui
        log_ok "ROG Control Center instalado"
    fi

    log_step "3/3 · Resumen"
    log_ok "Configuración ASUS finalizada"

    # Cardwire sigue deliberadamente fuera de este proyecto.
}

main "$@"
