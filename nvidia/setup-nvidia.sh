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
#   - glx-utils / glxinfo
#   - wrapper nvidia-run para PRIME Render Offload
#   - verificación funcional del renderizado OpenGL
#
# Requiere un usuario normal con sudo. No ejecutar como root.
# No soporta variantes Atomic (Silverblue/Kinoite).
#
# Uso:
#   ./setup-nvidia.sh            instala/actualiza y verifica (idempotente)
#   ./setup-nvidia.sh --verify   solo verifica; usar tras reiniciar
#   ./setup-nvidia.sh --help
#
# Flujo normal en una primera instalación:
#   1) ./setup-nvidia.sh           -> instala; avisa de que falta reiniciar
#   2) reiniciar
#   3) ./setup-nvidia.sh --verify  -> comprueba driver y PRIME Render Offload
#
# Códigos de salida:
#   0  correcto: instalado y verificado; o instalado y pendiente de reinicio
#      (el script lo indica); o sin GPU NVIDIA
#   1  error o abortado por el usuario
#   3  el driver no funciona y ningún reinicio pendiente lo explica; o, con
#      --verify, la verificación no se pudo completar con éxito

set -uo pipefail

MODE="install"
SB_ENABLED=0
DRIVER_STATE="unknown"   # active | reboot | broken
REBOOT_PENDING=0

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

usage() {
    cat <<'EOF'
Uso: setup-nvidia.sh [--verify] [--help]

  (sin argumentos)  Instala/actualiza el soporte NVIDIA y verifica.
                    Es seguro volver a ejecutarlo.
  --verify          Solo verifica el driver y PRIME Render Offload.
                    Úsalo después de reiniciar, desde una terminal del escritorio.
  -h, --help        Muestra esta ayuda.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verify)  MODE="verify" ;;
            -h|--help) usage; exit 0 ;;
            *)
                log_err "Argumento desconocido: $1"
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
}

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

# Devuelve 0 si hay un dispositivo PCI de clase display (03xx) con vendor
# NVIDIA (10de); 1 si no; 2 si no se pudo comprobar. Filtrar por clase evita
# falsos positivos con otros dispositivos NVIDIA que no son GPU.
detect_nvidia() {
    if ! command -v lspci &>/dev/null; then
        log_err "No se encontró lspci; no se puede comprobar si hay una GPU NVIDIA."
        return 2
    fi

    local lspci_out
    lspci_out="$(lspci -nn 2>/dev/null)" || return 2

    grep -Eiq '\[03[0-9a-f]{2}\]:.*\[10de:' <<<"$lspci_out"
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
        SB_ENABLED=1
        log_warn "Secure Boot está ACTIVO. El módulo NVIDIA no cargará sin firmarlo y enrolar la clave MOK."

        if [[ "$MODE" == "install" ]]; then
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

    # Solo se recompila si no hay un módulo de la versión instalada para el
    # kernel en ejecución; así las re-ejecuciones no repiten la compilación.
    local mod_ver pkg_ver
    mod_ver="$(modinfo -k "$(uname -r)" -F version nvidia 2>/dev/null || true)"
    pkg_ver="$(rpm -q --qf '%{VERSION}' akmod-nvidia 2>/dev/null || true)"

    if [[ -n "$mod_ver" && "$mod_ver" == "$pkg_ver" ]]; then
        log_ok "Módulo NVIDIA $mod_ver ya disponible para $(uname -r)"
        return 0
    fi

    log_info "Compilando el módulo NVIDIA para el kernel actual..."
    if sudo akmods --force --kernels "$(uname -r)"; then
        log_ok "Módulo NVIDIA compilado para $(uname -r)"
    else
        log_err "akmods no terminó correctamente. No reinicies todavía; revisa el estado de akmods y los logs del kernel."
        return 1
    fi
}

install_gl_tools() {
    log_step "3/7 · Instalando diagnóstico OpenGL (glx-utils)"

    if ! sudo dnf install -y glx-utils; then
        log_err "No se pudo instalar glx-utils."
        return 1
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

# Estado del driver en el arranque actual:
#   active  nvidia-smi se comunica con el driver
#   reboot  el driver no responde y nouveau/nova_core siguen cargados: el
#           reinicio con la blacklist aplicada es lo que falta
#   broken  el driver no responde y no hay un reinicio pendiente que lo explique
nvidia_driver_state() {
    if nvidia-smi -L &>/dev/null; then
        echo "active"
    elif [[ -d /sys/module/nouveau || -d /sys/module/nova_core ]]; then
        echo "reboot"
    else
        echo "broken"
    fi
}

# 0 = el kernel por defecto lleva la blacklist de nouveau; 1 = no la lleva;
# 2 = no se pudo comprobar.
blacklist_configured() {
    command -v grubby &>/dev/null || return 2

    local args
    args="$(sudo grubby --info=DEFAULT 2>/dev/null | grep '^args=')" || return 2

    grep -Eq '(modprobe|rd\.driver)\.blacklist=[^ "]*nouveau' <<<"$args"
}

diagnose_broken_driver() {
    if ! modinfo -k "$(uname -r)" nvidia &>/dev/null; then
        log_err "No hay módulo nvidia instalado para el kernel en ejecución ($(uname -r))."
        log_info "Revisa: sudo journalctl -u akmods --no-pager | tail -n 40"
        log_info "        ls /var/cache/akmods/nvidia/"
    else
        log_err "El módulo nvidia existe para $(uname -r), pero no enlaza con la GPU."
        log_info "Revisa: journalctl -b -k --no-pager | grep -iE 'nvidia|NVRM|nouveau'"
    fi

    if [[ "$SB_ENABLED" -eq 1 ]]; then
        log_warn "Secure Boot está activo: comprueba que la clave de akmods está enrolada en MOK."
    fi
}

show_gpu_topology() {
    log_step "5/7 · Comprobando driver y topología gráfica"

    DRIVER_STATE="$(nvidia_driver_state)"

    case "$DRIVER_STATE" in
        active)
            nvidia-smi -L
            log_ok "El driver NVIDIA está cargado y responde"
            ;;
        reboot)
            REBOOT_PENDING=1
            log_info "El driver NVIDIA aún no está activo: nouveau/nova_core siguen cargados en este arranque."
            log_info "Es lo esperado justo tras instalar; hace falta reiniciar."

            local bl_rc=0
            blacklist_configured || bl_rc=$?
            if [[ "$bl_rc" -eq 1 ]]; then
                log_warn "El kernel por defecto no lleva la blacklist de nouveau; reiniciar podría no bastar."
                log_info "Revisa: sudo grubby --info=DEFAULT | grep '^args='"
            fi
            ;;
        *)
            log_warn "El driver NVIDIA no responde y no hay un reinicio pendiente que lo explique."
            diagnose_broken_driver
            ;;
    esac
}

# Devuelve:
#   0  verificado: nvidia-run usa NVIDIA
#   1  fallo real
#   2  no se pudo verificar (reinicio pendiente o sin sesión gráfica)
verify_prime_offload() {
    log_step "6/7 · Verificación funcional de PRIME Render Offload"

    case "$DRIVER_STATE" in
        reboot)
            log_info "Verificación omitida: el driver NVIDIA aún no está activo en este arranque."
            return 2
            ;;
        broken)
            log_err "Verificación imposible: el driver NVIDIA no responde."
            return 1
            ;;
    esac

    if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
        log_warn "Este terminal no tiene sesión gráfica (sin WAYLAND_DISPLAY ni DISPLAY); no se puede probar OpenGL."
        log_info "Ejecuta './setup-nvidia.sh --verify' desde un terminal dentro del escritorio."
        return 2
    fi

    if ! command -v glxinfo &>/dev/null; then
        log_err "Falta glxinfo; no se puede comprobar OpenGL."
        return 1
    fi

    if ! command -v nvidia-run &>/dev/null; then
        log_err "nvidia-run no está disponible; no se puede probar el offload."
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

    log_info "Renderizador OpenGL mediante nvidia-run:"
    local nvidia_output
    local nvidia_status=0
    nvidia_output="$(nvidia-run glxinfo 2>/dev/null)" || nvidia_status=$?

    if [[ "$nvidia_status" -ne 0 ]]; then
        log_err "nvidia-run glxinfo terminó con código $nvidia_status con el driver activo."
        return 1
    fi

    local nvidia_renderer
    nvidia_renderer="$(printf '%s\n' "$nvidia_output" | awk -F': ' '/OpenGL renderer string/ {print $2; exit}')"

    if [[ -z "$nvidia_renderer" ]]; then
        log_err "No se pudo obtener el renderizador NVIDIA mediante nvidia-run."
        return 1
    fi

    echo "  $nvidia_renderer"

    if ! grep -qi NVIDIA <<<"$nvidia_renderer"; then
        log_err "nvidia-run respondió, pero el renderizador no es NVIDIA."
        return 1
    fi

    if [[ -n "$normal_renderer" ]] && grep -qi NVIDIA <<<"$normal_renderer"; then
        log_ok "El renderizador predeterminado ya es NVIDIA (el offload no es necesario) y nvidia-run funciona"
        return 0
    fi

    log_ok "PRIME Render Offload funciona: OpenGL está usando NVIDIA"
    return 0
}

secure_boot_notes() {
    echo
    echo "Secure Boot está activo: el módulo NVIDIA debe estar firmado con una clave enrolada en MOK."
    echo "  1) Si no existe /etc/pki/akmods/certs/public_key.der:  sudo kmodgenca -a"
    echo "  2) sudo mokutil --import /etc/pki/akmods/certs/public_key.der"
    echo "  3) Reinicia y completa 'Enroll MOK' en la pantalla azul con la contraseña que definiste."
    echo "  4) Si el módulo se compiló antes de existir la clave, recompílalo:"
    echo "     sudo akmods --force --kernels \"\$(uname -r)\""
    echo "(Camino no probado por este script en un equipo real; consulta la documentación de RPM Fusion.)"
}

final_summary() {
    log_step "7/7 · Resumen"

    if pkg_installed akmod-nvidia; then log_ok "akmod-nvidia instalado"; else log_warn "akmod-nvidia no está instalado"; fi
    if pkg_installed xorg-x11-drv-nvidia-cuda; then log_ok "xorg-x11-drv-nvidia-cuda instalado"; else log_warn "xorg-x11-drv-nvidia-cuda no está instalado"; fi
    if pkg_installed libva-nvidia-driver; then log_ok "libva-nvidia-driver instalado"; else log_warn "libva-nvidia-driver no está instalado"; fi

    if command -v nvidia-smi &>/dev/null; then log_ok "nvidia-smi disponible"; else log_warn "nvidia-smi no disponible"; fi
    if command -v glxinfo &>/dev/null; then log_ok "glxinfo disponible"; else log_warn "glxinfo no disponible"; fi
    if [[ -x /usr/local/bin/nvidia-run ]]; then log_ok "nvidia-run instalado"; else log_warn "nvidia-run no está instalado"; fi

    if [[ "$SB_ENABLED" -eq 1 ]]; then
        secure_boot_notes
    fi

    if [[ "$REBOOT_PENDING" -eq 1 ]]; then
        echo
        echo "Reinicia y, desde un terminal del escritorio, ejecuta:"
        echo "  ./setup-nvidia.sh --verify"
        echo
        echo "o comprueba a mano:"
        echo "  nvidia-smi"
        echo '  nvidia-run glxinfo | grep "OpenGL renderer"'
    fi
}

main() {
    parse_args "$@"
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

    if [[ "$MODE" == "install" ]]; then
        ensure_rpmfusion || exit 1
        install_nvidia_stack || exit 1
        install_gl_tools || exit 1
        install_nvidia_run
    fi

    show_gpu_topology

    local verify_rc=0
    verify_prime_offload || verify_rc=$?

    final_summary

    echo
    if [[ "$verify_rc" -eq 1 ]]; then
        if [[ "$MODE" == "verify" ]]; then
            log_err "Verificación no superada; revisa los detalles anteriores."
        else
            log_err "El driver NVIDIA no funciona y ningún reinicio pendiente lo explica; revisa el diagnóstico anterior."
        fi
        exit 3
    fi

    if [[ "$MODE" == "verify" && "$verify_rc" -ne 0 ]]; then
        log_err "Verificación no superada; revisa los detalles anteriores."
        exit 3
    fi

    if [[ "$verify_rc" -eq 0 ]]; then
        log_ok "Instalación y verificación completadas."
        exit 0
    fi

    if [[ "$REBOOT_PENDING" -eq 1 ]]; then
        log_info "Instalación completada. Falta reiniciar para activar el driver NVIDIA."
    else
        log_warn "Instalación completada, pero la verificación gráfica no se pudo ejecutar desde este terminal."
    fi
    exit 0
}

main "$@"