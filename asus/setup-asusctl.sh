#!/usr/bin/env bash
#
# setup-asusctl.sh
#
# Configuración de asusctl / asusd / ROG Control Center y Cardwire (gestor de
# GPU híbrida) para hardware ASUS. Los paquetes vienen de Terra (repo de
# terceros de Fyra Labs).
# Este componente es independiente de setup-fedora-plasma.sh.
#
# Uso:
#   chmod +x setup-asusctl.sh
#   ./setup-asusctl.sh
#
# Requiere un usuario normal con sudo. No ejecutar como root.
#
# Códigos de salida:
#   0  correcto, o sin hardware ASUS, o el usuario omitió todo
#   1  error: no se pudo habilitar Terra o no se pudo instalar/activar Cardwire

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
            *) echo "  Responde 's' o 'n'." ;;
        esac
    done
}

require_root_privileges() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_err "No corras este script directamente como root. Ejecútalo como tu usuario normal."
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

# Habilita Terra (repo de terceros de Fyra Labs) si no lo está.
ensure_terra() {
    if rpm -q terra-release &>/dev/null || \
       dnf repolist --enabled 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx 'terra'; then
        log_ok "Terra ya está habilitado"
        return 0
    fi

    log_warn "Terra es un repositorio de terceros (Fyra Labs)."
    log_info "Para quitarlo después: sudo dnf remove terra-release"

    if sudo dnf install -y --nogpgcheck \
        --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
        terra-release; then
        log_ok "Terra habilitado"
    else
        log_err "No se pudo habilitar Terra. Instrucciones oficiales: https://developer.fyralabs.com/terra/installing"
        return 1
    fi
}

install_asusctl() {
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
}

# El demonio de Cardwire se niega a arrancar si 'bpf' no está entre los LSM activos.
check_bpf_lsm() {
    local lsm
    lsm="$(cat /sys/kernel/security/lsm 2>/dev/null || true)"

    if [[ ",$lsm," == *,bpf,* ]]; then
        log_ok "BPF LSM activo (requisito de Cardwire)"
    else
        log_warn "'bpf' no figura en /sys/kernel/security/lsm: cardwired no arrancará."
        log_info "Comprueba: cat /sys/kernel/security/lsm   y   grep CONFIG_BPF_LSM /boot/config-\$(uname -r)"
    fi
}

enable_cardwired() {
    check_bpf_lsm

    if ! systemctl cat cardwired.service &>/dev/null; then
        log_err "No se encontró cardwired.service tras instalar cardwire."
        return 1
    fi

    if sudo systemctl enable --now cardwired.service; then
        log_ok "cardwired habilitado e iniciado"
    else
        log_err "No se pudo habilitar/iniciar cardwired."
        log_info "Revisa: systemctl status cardwired.service   y   journalctl -u cardwired -b --no-pager | tail -n 40"
        return 1
    fi
}

# La GUI es un paquete aparte (cardwire-gui). Es opcional: la CLI y el demonio
# funcionan sin ella, así que un fallo solo avisa.
install_cardwire_gui() {
    if pkg_installed cardwire-gui; then
        log_ok "cardwire-gui ya está instalado"
    elif sudo dnf install -y cardwire-gui; then
        log_ok "cardwire-gui instalado"
    else
        log_warn "No se pudo instalar cardwire-gui (opcional; la CLI y el demonio funcionan sin ella)."
    fi
}

install_cardwire() {
    if [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
        log_warn "Cardwire solo soporta Wayland y esta sesión es X11."
    fi

    if pkg_installed cardwire; then
        log_ok "cardwire ya está instalado"
    # --allowerasing: Fedora trae instalado un paquete con el que cardwire
    # declara conflicto (cardwire lo provee y lo sustituye).
    elif sudo dnf install -y --allowerasing cardwire; then
        log_ok "cardwire instalado"
    else
        log_err "No se pudo instalar cardwire. Revisa el mensaje de dnf."
        return 1
    fi

    install_cardwire_gui
    enable_cardwired
}

main() {
    require_root_privileges

    log_step "1/5 · Detectando hardware ASUS"

    local vendor
    vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")"

    if [[ "$vendor" != *ASUS* ]]; then
        log_info "No se detectó hardware ASUS (fabricante detectado: '${vendor:-desconocido}')."
        return 0
    fi

    log_info "Hardware ASUS detectado ($vendor)"

    local want_asusctl=0 want_cardwire=0

    if ask_yes_no "¿Instalar herramientas ASUS Linux (asusctl)?"; then
        want_asusctl=1
    else
        log_info "Se omite asusctl a pedido del usuario"
    fi

    if ask_yes_no "¿Instalar Cardwire (gestor de GPU híbrida)?"; then
        want_cardwire=1
    else
        log_info "Se omite Cardwire a pedido del usuario"
    fi

    if [[ "$want_asusctl" -eq 0 && "$want_cardwire" -eq 0 ]]; then
        return 0
    fi

    log_step "2/5 · Habilitando repositorio Terra"
    ensure_terra || return 1

    local rc=0

    if [[ "$want_asusctl" -eq 1 ]]; then
        log_step "3/5 · Instalando asusctl y configurando servicios"
        install_asusctl
    fi

    if [[ "$want_cardwire" -eq 1 ]]; then
        log_step "4/5 · Instalando Cardwire"
        install_cardwire || rc=1
    fi

    log_step "5/5 · Resumen"
    if [[ "$rc" -eq 0 ]]; then
        log_ok "Configuración ASUS finalizada"
    else
        log_err "Configuración ASUS terminada con errores (ver mensajes anteriores)."
    fi

    return "$rc"
}

main "$@"