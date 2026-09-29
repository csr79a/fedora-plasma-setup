#!/usr/bin/env bash
#
# setup-nvidia.sh
#
# Configuración y verificación del soporte NVIDIA para Fedora.
# Componente independiente de Plasma y Gaming.
#
# Incluye:
#   - detección de GPU NVIDIA
#   - RPM Fusion Nonfree
#   - akmod-nvidia
#   - libva-nvidia-driver
#   - switcheroo-control / switcherooctl
#   - glx-utils / glxinfo
#   - wrapper nvidia-run para PRIME Render Offload
#   - verificación funcional del renderizado OpenGL
#
# Requiere un usuario normal con sudo. No ejecutar como root.

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

ask_yes_no() {
    local prompt="$1"
    local answer
    while true; do
        read -rp "$(echo -e "$COLOR_YELLOW?$COLOR_RESET $prompt [s/n]: ")" answer
        case "$answer" in
            s|S|si|SI|Si|sí|Sí|y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) echo "  Respondé 's' o 'n'." ;;
        esac
    done
}

require_user() {
    if [[ "$EUID" -eq 0 ]]; then
        log_err "No corras este script directamente como root. Ejecutalo como usuario normal."
        exit 1
    fi
    if ! command -v sudo &>/dev/null; then
        log_err "No se encontró sudo."
        exit 1
    fi
    sudo -v
}

pkg_installed() {
    rpm -q "$1" &>/dev/null
}

detect_nvidia() {
    command -v lspci &>/dev/null || return 1
    lspci -nn | grep -qi nvidia
}

ensure_rpmfusion() {
    log_step "1/7 · Preparando RPM Fusion Nonfree"

    if rpm -q rpmfusion-nonfree-release &>/dev/null; then
        log_ok "RPM Fusion Nonfree ya está instalado"
        return 0
    fi

    local release
    release="$(rpm -E %fedora)"

    if sudo dnf install -y "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$release.noarch.rpm"; then
        log_ok "RPM Fusion Nonfree habilitado"
    else
        log_err "No se pudo habilitar RPM Fusion Nonfree."
        return 1
    fi
}

install_nvidia_stack() {
    log_step "2/7 · Instalando soporte NVIDIA"

    sudo dnf install -y         akmod-nvidia         xorg-x11-drv-nvidia-cuda         libva-nvidia-driver

    log_ok "Paquetes NVIDIA instalados"

    log_info "Forzando compilación del módulo NVIDIA para el kernel actual..."
    if sudo akmods --force --kernels "$(uname -r)"; then
        log_ok "Módulo NVIDIA compilado para $(uname -r)"
    else
        log_warn "akmods no terminó correctamente; revisá su estado antes de reiniciar."
    fi
}

install_hybrid_tools() {
    log_step "3/7 · Preparando GPU híbrida y diagnóstico OpenGL"

    sudo dnf install -y switcheroo-control glx-utils

    if systemctl list-unit-files switcheroo-control.service &>/dev/null; then
        sudo systemctl enable --now switcheroo-control.service || true
        log_ok "switcheroo-control habilitado"
    else
        log_warn "No se encontró switcheroo-control.service."
    fi

    command -v switcherooctl &>/dev/null         && log_ok "switcherooctl disponible"         || log_warn "switcherooctl no está disponible."

    command -v glxinfo &>/dev/null         && log_ok "glxinfo disponible"         || log_warn "glxinfo no está disponible."
}

install_nvidia_run() {
    log_step "4/7 · Instalando wrapper nvidia-run"

    local target="/usr/local/bin/nvidia-run"

    sudo tee "$target" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

if [[ $# -eq 0 ]]; then
    echo "Uso: nvidia-run <comando> [argumentos...]"
    echo "Ejemplo: nvidia-run glxinfo"
    exit 2
fi

exec env     __NV_PRIME_RENDER_OFFLOAD=1     __GLX_VENDOR_LIBRARY_NAME=nvidia     __VK_LAYER_NV_optimus=NVIDIA_only     VK_LOADER_DRIVERS_SELECT='*nvidia*'     "$@"
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

verify_prime_offload() {
    log_step "6/7 · Verificación funcional de PRIME Render Offload"

    if ! command -v glxinfo &>/dev/null; then
        log_warn "Falta glxinfo; no se puede comprobar OpenGL."
        return
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
        return
    fi

    log_info "Renderizador OpenGL mediante nvidia-run:"
    local nvidia_renderer
    nvidia_renderer="$(nvidia-run glxinfo 2>/dev/null | awk -F': ' '/OpenGL renderer string/ {print $2; exit}' || true)"

    if [[ -n "$nvidia_renderer" ]]; then
        echo "  $nvidia_renderer"
        if echo "$nvidia_renderer" | grep -qi NVIDIA; then
            log_ok "PRIME Render Offload funciona: OpenGL está usando NVIDIA"
        else
            log_warn "nvidia-run respondió, pero el renderizador no parece ser NVIDIA."
        fi
    else
        log_warn "No se pudo obtener el renderizador NVIDIA mediante nvidia-run."
        log_info "Si acabás de instalar el driver, reiniciá y repetí la prueba."
    fi
}

final_summary() {
    log_step "7/7 · Resumen"

    pkg_installed akmod-nvidia         && log_ok "akmod-nvidia instalado"         || log_warn "akmod-nvidia no está instalado"

    command -v nvidia-smi &>/dev/null         && log_ok "nvidia-smi disponible"         || log_warn "nvidia-smi no disponible"

    command -v switcherooctl &>/dev/null         && log_ok "switcherooctl disponible"         || log_warn "switcherooctl no disponible"

    command -v glxinfo &>/dev/null         && log_ok "glxinfo disponible"         || log_warn "glxinfo no disponible"

    [[ -x /usr/local/bin/nvidia-run ]]         && log_ok "nvidia-run instalado"         || log_warn "nvidia-run no está instalado"

    echo
    echo "Pruebas manuales después de reiniciar:"
    echo "  nvidia-smi"
    echo "  switcherooctl list"
    echo '  glxinfo | grep "OpenGL renderer"'
    echo '  nvidia-run glxinfo | grep "OpenGL renderer"'
    echo
    echo "En un sistema híbrido, la última prueba debería mostrar una GPU NVIDIA."
    echo "Si Secure Boot está activo y el módulo no carga, revisá el enrolamiento MOK."
}

main() {
    require_user

    log_step "Preflight"

    if ! detect_nvidia; then
        log_warn "No se detectó una GPU NVIDIA. No se instalará el stack NVIDIA."
        exit 0
    fi

    log_ok "GPU NVIDIA detectada"

    ensure_rpmfusion || exit 1
    install_nvidia_stack
    install_hybrid_tools
    install_nvidia_run
    show_gpu_topology
    verify_prime_offload
    final_summary

    echo
    log_info "Se recomienda reiniciar antes de validar PRIME Render Offload."
}

main "$@"
