#!/usr/bin/env bash
#
# setup-nvidia.sh
#
# Configuración del soporte NVIDIA propietario para Fedora.
# Este componente es independiente de setup-fedora-plasma.sh.
#
# Uso:
#   chmod +x setup-nvidia.sh
#   ./setup-nvidia.sh
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

    log_step "1/3 · Detectando GPU NVIDIA"

    if ! command -v lspci &>/dev/null; then
        log_err "No se encontró 'lspci'. Instalá pciutils y volvé a ejecutar el script."
        exit 1
    fi

    local gpu_info
    gpu_info="$(lspci -nnk | grep -iE 'vga|3d controller' -A2 || true)"

    if ! echo "$gpu_info" | grep -qi 'nvidia'; then
        log_warn "No se detectó una GPU NVIDIA. No se instalará el driver."
        return 0
    fi

    echo "$gpu_info"
    log_ok "GPU NVIDIA detectada"

    log_step "2/3 · Instalando soporte NVIDIA"

    log_info "Instalando códecs VAAPI NVIDIA"
    sudo dnf install -y libva-nvidia-driver
    log_ok "Códecs NVIDIA (libva-nvidia-driver) instalados"

    echo
    log_warn "El driver propietario NVIDIA (akmod-nvidia) compila un módulo de kernel."
    log_warn "Si tenés Secure Boot ACTIVADO, hay un paso manual de firma (MOK enrollment)"
    log_warn "que este script NO hace por vos — está documentado en MANUAL.md."

    if ask_yes_no "¿Instalar el driver propietario NVIDIA (akmod-nvidia)?"; then
        sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda
        log_info "Compilando el módulo de kernel de NVIDIA (esto puede tardar unos minutos)..."
        sudo akmods --force --kernels "$(uname -r)"
        log_ok "akmod-nvidia instalado y módulo compilado. Se recomienda reiniciar."
    else
        log_info "Se omite la instalación de akmod-nvidia."
    fi

    log_step "3/3 · Resumen"
    if pkg_installed akmod-nvidia; then
        log_ok "akmod-nvidia está instalado"
    else
        log_info "akmod-nvidia no está instalado"
    fi
    echo "Si tenés Secure Boot activado, revisá MANUAL.md para el MOK enrollment."
}

main "$@"
