#!/usr/bin/env bash
#
# setup-nvidia.sh
#
# Configuración y verificación del soporte NVIDIA para Fedora (Workstation/KDE).
# Componente independiente de Plasma y Gaming.
#
# Incluye:
#   - detección de GPU NVIDIA
#   - comprobación de Secure Boot
#   - RPM Fusion Free y Nonfree
#   - akmod-nvidia
#   - xorg-x11-drv-nvidia-cuda (aporta nvidia-smi y las librerías CUDA)
#   - libva-nvidia-driver
#   - switcheroo-control / switcherooctl
#   - glx-utils / glxinfo
#   - wrapper nvidia-run para PRIME Render Offload
#   - verificación funcional del renderizado OpenGL
#
# Requiere un usuario normal con sudo. No ejecutar como root.
# No soporta variantes Atomic (Silverblue/Kinoite).
#
# Códigos de salida:
#   0  todo instalado y PRIME Render Offload verificado (o sin GPU NVIDIA)
#   1  error o abortado por el usuario
#   3  instalación correcta, pero la verificación de offload no se pudo
#      confirmar (normalmente falta reiniciar)

set -uo pipefail

COLOR_RESET="\e[0m"
COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_BLUE="\e[34m"

log_info() { echo -e "$COLOR_BLUE[INFO]$COLOR_RESET $*"; }
log_ok()   { echo -e "$COLOR_GREEN[ OK ]$COLOR_RESET $*"; }
log_warn() { echo -e "$COLOR_YELLOW[WARN]$COLOR_RESET $*"; }
log_err()  { echo -e "$COLOR_RED[FAIL]$COLOR_RESET $*"; }
log_step() { echo -e "\n$COLOR_BLUE==>$COLOR_RESET \e[1m$*$COLOR_RESET"; }

SUDO_KEEPALIVE_PID=""

require_not_root() {
    if [[ "$EUID" -eq 0 ]]; then
        log_err "No corras este script directamente como root. Ejecútalo como usuario normal."
        exit 1
    fi
    if ! command -v sudo &>/dev/null; then
        log_err "No se encontró sudo."
        exit 1
    fi
}

# Pide la contraseña de sudo y mantiene vigente el timestamp durante la
# ejecución (dnf + akmods pueden tardar más que el timeout de sudo).
ensure_sudo() {
    sudo -v || { log_err "No se pudo obtener privilegios sudo."; exit 1; }

    (
        while kill -0 "$$" 2>/dev/null; do
            sudo -n true 2>/dev/null || exit 0
            sleep 50
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

pkg_installed() {
    rpm -q "$1" &>/dev/null
}

require_fedora() {
    if [[ ! -r /etc/os-release ]]; then
        log_err "No se pudo leer /etc/os-release. No es posible verificar el sistema operativo."
        exit 1
    fi

    local os_id
    os_id="$(. /etc/os-release; echo "${ID:-}")"

    if [[ "$os_id" != "fedora" ]]; then
        log_err "Este script está diseñado para Fedora. Sistema detectado: ID=${os_id:-desconocido}."
        exit 1
    fi

    if [[ -e /run/ostree-booted ]]; then
        log_err "Se detectó una variante Atomic (rpm-ostree). Este script usa dnf y no es válido ahí."
        exit 1
    fi
}

detect_nvidia() {
    if ! command -v lspci &>/dev/null; then
        log_err "No se encontró lspci; no se puede comprobar si hay una GPU NVIDIA."
        return 2
    fi

    local lspci_out
    lspci_out="$(lspci -nn 2>/dev/null)" || return 2

    grep -qi nvidia <<<"$lspci_out"
}

# Con Secure Boot activo, el módulo compilado por akmods no carga sin firma
# y enrolamiento MOK. Se avisa antes de modificar nada.
check_secure_boot() {
    if ! command -v mokutil &>/dev/null; then
        log_warn "mokutil no está disponible; no se puede comprobar Secure Boot."
        return 0
    fi

    local sb_state
    sb_state="$(mokutil --sb-state 2>/dev/null || true)"

    if grep -qi 'SecureBoot enabled' <<<"$sb_state"; then
        log_warn "Secure Boot está ACTIVO. El módulo NVIDIA no cargará sin firmarlo y enrolar la clave MOK."
        log_warn "Si es la única GPU o la que usa el escritorio, podrías quedarte sin gráficos tras reiniciar."

        if [[ -t 0 ]]; then
            local answer
            read -r -p "¿Continuar de todos modos? [s/N] " answer
            if [[ "${answer,,}" != s* ]]; then
                log_info "Abortado por el usuario."
                exit 1
            fi
        else
            log_err "Ejecución no interactiva con Secure Boot activo; se aborta por seguridad."
            exit 1
        fi
    elif grep -qi 'SecureBoot disabled' <<<"$sb_state"; then
        log_ok "Secure Boot desactivado; el módulo cargará sin firma"
    else
        log_warn "No se pudo determinar el estado de Secure Boot."
    fi
}

ensure_rpmfusion() {
    log_step "1/7 · Preparando RPM Fusion (Free y Nonfree)"

    local release
    release="$(rpm -E %fedora)"

    local -a to_install=()

    if rpm -q rpmfusion-free-release &>/dev/null; then
        log_ok "RPM Fusion Free ya está instalado"
    else
        to_install+=("https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$release.noarch.rpm")
    fi

    if rpm -q rpmfusion-nonfree-release &>/dev/null; then
        log_ok "RPM Fusion Nonfree ya está instalado"
    else
        to_install+=("https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$release.noarch.rpm")
    fi

    if [[ "${#to_install[@]}" -eq 0 ]]; then
        return 0
    fi

    if sudo dnf install -y "${to_install[@]}"; then
        log_ok "RPM Fusion habilitado"
    else
        log_err "No se pudo habilitar RPM Fusion."
        return 1
    fi
}

install_nvidia_stack() {
    log_step "2/7 · Instalando soporte NVIDIA"

    if ! sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda libva-nvidia-driver; then
        log_err "No se pudieron instalar todos los paquetes NVIDIA requeridos."
        return 1
    fi

    log_ok "Paquetes NVIDIA instalados"

    log_info "Forzando compilación del módulo NVIDIA para el kernel actual..."
    if sudo akmods --force --kernels "$(uname -r)"; then
        log_ok "Módulo NVIDIA compilado para $(uname -r)"
    else
        log_err "akmods no terminó correctamente. No reinicies todavía; revisa el estado de akmods y los logs del kernel."
        return 1
    fi
}

install_hybrid_tools() {
    log_step "3/7 · Preparando GPU híbrida y diagnóstico OpenGL"

    if ! sudo dnf install -y switcheroo-control glx-utils; then
        log_err "No se pudieron instalar switcheroo-control y glx-utils."
        return 1
    fi

    if systemctl cat switcheroo-control.service &>/dev/null; then
        if sudo systemctl enable --now switcheroo-control.service; then
            log_ok "switcheroo-control habilitado"
        else
            log_warn "La unidad switcheroo-control.service existe, pero no se pudo habilitar/iniciar."
        fi
    else
        log_warn "No se encontró switcheroo-control.service."
    fi

    if command -v switcherooctl &>/dev/null; then
        log_ok "switcherooctl disponible"
    else
        log_warn "switcherooctl no está disponible."
    fi

    if command -v glxinfo &>/dev/null; then
        log_ok "glxinfo disponible"
    else
        log_warn "glxinfo no está disponible."
    fi
}

install_nvidia_run() {
    log_step "4/7 · Instalando wrapper nvidia-run"

    local target="/usr/local/bin/nvidia-run"

    if [[ -e "$target" ]] && ! grep -qF '# nvidia-run — gestionado por setup-nvidia.sh' "$target" 2>/dev/null; then
        log_warn "$target ya existe y no parece gestionado por este script; no se sobrescribirá."
        return 0
    fi

    sudo tee "$target" >/dev/null <<'EOF'
#!/usr/bin/env bash
# nvidia-run — gestionado por setup-nvidia.sh
set -uo pipefail

if [[ $# -eq 0 ]]; then
    echo "Uso: nvidia-run <comando> [argumentos...]"
    echo "Ejemplo: nvidia-run glxinfo"
    exit 2
fi

if command -v nvidia-smi &>/dev/null && ! nvidia-smi -L &>/dev/null; then
    echo "Advertencia: nvidia-smi no puede comunicarse con el driver NVIDIA." >&2
fi

exec env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only VK_LOADER_DRIVERS_SELECT='*nvidia*' "$@"
EOF

    sudo chmod 0755 "$target"

    if [[ -x "$target" ]]; then
        log_ok "Instalado $target"
    else
        log_warn "No se pudo verificar $target"
    fi
}

show_gpu_topology() {
    log_step "5/7 · Comprobando topología gráfica"

    if command -v nvidia-smi &>/dev/null; then
        if nvidia-smi --query-gpu=name,pci.bus_id,driver_version --format=csv,noheader 2>/dev/null; then
            log_ok "nvidia-smi responde correctamente"
        else
            log_warn "nvidia-smi está instalado pero no pudo consultar la GPU."
        fi
    else
        log_warn "nvidia-smi todavía no está disponible."
    fi

    if command -v switcherooctl &>/dev/null; then
        echo
        switcherooctl list || log_warn "switcherooctl no pudo enumerar las GPU."
    fi
}

# Devuelve 0 solo si se demuestra que nvidia-run cambia el renderizador a NVIDIA.
verify_prime_offload() {
    log_step "6/7 · Verificación funcional de PRIME Render Offload"

    if ! command -v glxinfo &>/dev/null; then
        log_warn "Falta glxinfo; no se puede comprobar OpenGL."
        return 1
    fi

    log_info "Renderizador OpenGL predeterminado:"
    local normal_renderer
    normal_renderer="$(glxinfo 2>/dev/null | awk -F': ' '/OpenGL renderer string/ {print $2; exit}' || true)"

    if [[ -n "$normal_renderer" ]]; then
        echo "  $normal_renderer"
        log_ok "glxinfo funciona"
    else
        log_warn "No se pudo obtener el renderizador OpenGL predeterminado."
    fi

    if ! command -v nvidia-run &>/dev/null; then
        log_warn "nvidia-run no está disponible; se omite la prueba de offload."
        return 1
    fi

    log_info "Renderizador OpenGL mediante nvidia-run:"
    local nvidia_output
    local nvidia_status=0
    nvidia_output="$(nvidia-run glxinfo 2>/dev/null)" || nvidia_status=$?

    if [[ "$nvidia_status" -ne 0 ]]; then
        log_warn "nvidia-run glxinfo terminó con código $nvidia_status."
        log_info "Si acabas de instalar el driver, reinicia y repite la prueba."
        return 1
    fi

    local nvidia_renderer
    nvidia_renderer="$(printf '%s\n' "$nvidia_output" | awk -F': ' '/OpenGL renderer string/ {print $2; exit}')"

    if [[ -z "$nvidia_renderer" ]]; then
        log_warn "No se pudo obtener el renderizador NVIDIA mediante nvidia-run."
        log_info "Si acabas de instalar el driver, reinicia y repite la prueba."
        return 1
    fi

    echo "  $nvidia_renderer"

    if ! grep -qi NVIDIA <<<"$nvidia_renderer"; then
        log_warn "nvidia-run respondió correctamente, pero el renderizador no parece ser NVIDIA."
        return 1
    fi

    if [[ -n "$normal_renderer" ]] && grep -qi NVIDIA <<<"$normal_renderer"; then
        log_warn "nvidia-run usa NVIDIA, pero el renderizador predeterminado ya era NVIDIA; no se puede demostrar un cambio de offload."
        return 1
    fi

    log_ok "PRIME Render Offload funciona: OpenGL está usando NVIDIA"
    return 0
}

final_summary() {
    log_step "7/7 · Resumen"

    if pkg_installed akmod-nvidia; then log_ok "akmod-nvidia instalado"; else log_warn "akmod-nvidia no está instalado"; fi
    if pkg_installed xorg-x11-drv-nvidia-cuda; then log_ok "xorg-x11-drv-nvidia-cuda instalado"; else log_warn "xorg-x11-drv-nvidia-cuda no está instalado"; fi
    if pkg_installed libva-nvidia-driver; then log_ok "libva-nvidia-driver instalado"; else log_warn "libva-nvidia-driver no está instalado"; fi

    if command -v nvidia-smi &>/dev/null; then log_ok "nvidia-smi disponible"; else log_warn "nvidia-smi no disponible"; fi
    if command -v switcherooctl &>/dev/null; then log_ok "switcherooctl disponible"; else log_warn "switcherooctl no disponible"; fi
    if command -v glxinfo &>/dev/null; then log_ok "glxinfo disponible"; else log_warn "glxinfo no disponible"; fi
    if [[ -x /usr/local/bin/nvidia-run ]]; then log_ok "nvidia-run instalado"; else log_warn "nvidia-run no está instalado"; fi

    echo
    echo "Pruebas manuales después de reiniciar:"
    echo "  nvidia-smi"
    echo "  switcherooctl list"
    echo '  glxinfo | grep "OpenGL renderer"'
    echo '  nvidia-run glxinfo | grep "OpenGL renderer"'
    echo
    echo "En un sistema híbrido, la última prueba debería mostrar una GPU NVIDIA."
    echo "Si Secure Boot está activo y el módulo no carga, revisa el enrolamiento MOK."
}

main() {
    require_not_root
    require_fedora

    log_step "0/7 · Preflight"

    detect_nvidia
    local detection_status=$?
    if [[ "$detection_status" -eq 2 ]]; then
        exit 1
    elif [[ "$detection_status" -ne 0 ]]; then
        log_warn "No se detectó una GPU NVIDIA. No se instalará el stack NVIDIA."
        exit 0
    fi

    log_ok "GPU NVIDIA detectada"

    check_secure_boot
    ensure_sudo

    ensure_rpmfusion || exit 1
    install_nvidia_stack || exit 1
    install_hybrid_tools || exit 1
    install_nvidia_run

    show_gpu_topology

    local offload_ok=0
    verify_prime_offload || offload_ok=1

    final_summary

    echo
    if [[ "$offload_ok" -eq 0 ]]; then
        log_ok "Instalación y verificación completadas."
        exit 0
    fi

    log_info "Instalación completada, pero la verificación de offload no se pudo confirmar."
    log_info "Se recomienda reiniciar y repetir las pruebas manuales."
    exit 3
}

main "$@"