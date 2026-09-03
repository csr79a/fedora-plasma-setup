#!/usr/bin/env bash
#
# setup-fedora-plasma.sh
#
# Script de configuración inicial para Fedora Workstation / KDE Plasma spin.
# Deja el equipo listo con drivers multimedia, códecs por hardware (AMD/NVIDIA),
# microcódigo de CPU, Brave, Flathub y (opcionalmente) herramientas ASUS ROG.
#
# Uso:
#   chmod +x setup-fedora-plasma.sh
#   ./setup-fedora-plasma.sh
#
# Repite ejecución: el script es idempotente (se puede correr varias veces sin
# romper nada; cada paso comprueba si ya está hecho antes de actuar).

set -uo pipefail

# ---------------------------------------------------------------------------
# Utilidades de salida
# ---------------------------------------------------------------------------
COLOR_RESET="\e[0m"
COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_BLUE="\e[34m"

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_err()   { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"; }
log_step()  { echo -e "\n${COLOR_BLUE}==>${COLOR_RESET} \e[1m$*${COLOR_RESET}"; }

ask_yes_no() {
    # ask_yes_no "pregunta" -> devuelve 0 (si) o 1 (no)
    local prompt="$1"
    local answer
    while true; do
        read -rp "$(echo -e "${COLOR_YELLOW}?${COLOR_RESET} ${prompt} [s/n]: ")" answer
        case "${answer,,}" in
            s|si|sí|y|yes) return 0 ;;
            n|no)          return 1 ;;
            *) echo "  Respondé 's' o 'n'." ;;
        esac
    done
}

require_root_privileges() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_err "No corras este script directamente como root. Ejecutalo como tu usuario normal; se te pedirá la contraseña de sudo cuando haga falta."
        exit 1
    fi
    if ! command -v sudo &>/dev/null; then
        log_err "No se encontró 'sudo'. Instalalo o corré este script con un método equivalente."
        exit 1
    fi
    # Fuerza a pedir la contraseña una sola vez al principio
    sudo -v
}

pkg_installed() {
    rpm -q "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# 1. Base del sistema
# ---------------------------------------------------------------------------
step_base_update() {
    log_step "1/8 · Actualizando el sistema e instalando paquetes base"

    sudo dnf update --refresh -y
    sudo dnf upgrade -y

    local base_pkgs=(fastfetch unrar p7zip p7zip-plugins papirus-icon-theme)
    local to_install=()
    for pkg in "${base_pkgs[@]}"; do
        pkg_installed "$pkg" || to_install+=("$pkg")
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        sudo dnf install -y "${to_install[@]}"
        log_ok "Paquetes base instalados: ${to_install[*]}"
    else
        log_ok "Paquetes base ya estaban instalados"
    fi
}

# ---------------------------------------------------------------------------
# 2. RPM Fusion + multimedia
# ---------------------------------------------------------------------------
step_rpmfusion_multimedia() {
    log_step "2/8 · Habilitando RPM Fusion y configurando multimedia"

    local fedora_ver
    fedora_ver="$(rpm -E %fedora)"

    if ! pkg_installed rpmfusion-free-release; then
        sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_ver}.noarch.rpm"
    fi
    if ! pkg_installed rpmfusion-nonfree-release; then
        sudo dnf install -y \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_ver}.noarch.rpm"
    fi
    log_ok "RPM Fusion (free + nonfree) habilitado"

    sudo dnf update @core -y

    sudo dnf install -y rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data

    # Swap de ffmpeg-free por ffmpeg completo
    if pkg_installed ffmpeg-free; then
        sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
        log_ok "ffmpeg-free reemplazado por ffmpeg completo"
    elif pkg_installed ffmpeg; then
        log_ok "ffmpeg completo ya estaba instalado"
    else
        sudo dnf install -y ffmpeg
    fi

    # Grupo multimedia, excluyendo PackageKit-gstreamer-plugin
    sudo dnf group install -y Multimedia \
        --setopt="install_weak_deps=False" \
        --exclude=PackageKit-gstreamer-plugin
    log_ok "Grupo Multimedia instalado"
}

# ---------------------------------------------------------------------------
# 3. Microcódigo de CPU (detección automática Intel/AMD)
# ---------------------------------------------------------------------------
step_cpu_microcode() {
    log_step "3/8 · Detectando CPU e instalando microcódigo"

    local vendor
    vendor="$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $NF}')"

    case "$vendor" in
        GenuineIntel)
            log_info "CPU Intel detectada"
            if pkg_installed microcode_ctl; then
                log_ok "microcode_ctl ya estaba instalado"
            else
                sudo dnf install -y microcode_ctl
                log_ok "microcode_ctl instalado (microcódigo Intel)"
            fi
            ;;
        AuthenticAMD)
            log_info "CPU AMD detectada"
            # En Fedora el microcódigo AMD viene dentro de linux-firmware,
            # no como paquete separado (a diferencia de Debian con amd64-microcode).
            sudo dnf install -y linux-firmware
            log_ok "linux-firmware presente/actualizado (incluye microcódigo AMD)"
            ;;
        *)
            log_warn "No se pudo determinar el fabricante de la CPU (vendor_id='${vendor}'). Se omite este paso."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 4. GPU: códecs automáticos + NVIDIA propietario opcional
# ---------------------------------------------------------------------------
step_gpu_drivers() {
    log_step "4/8 · Detectando GPU e instalando códecs por hardware"

    local gpu_info
    gpu_info="$(lspci -nnk | grep -iE 'vga|3d controller' -A2)"

    local has_amd=false
    local has_nvidia=false
    echo "$gpu_info" | grep -qi 'amd\|ati' && has_amd=true
    echo "$gpu_info" | grep -qi 'nvidia' && has_nvidia=true

    if ! $has_amd && ! $has_nvidia; then
        log_warn "No se detectó GPU AMD ni NVIDIA (¿Intel integrada u otra?). Se omite este paso."
        return
    fi

    if $has_amd; then
        log_info "GPU AMD detectada → instalando códecs VAAPI"
        sudo dnf install -y mesa-va-drivers-freeworld
        sudo dnf install -y mesa-va-drivers-freeworld.i686 2>/dev/null \
            || log_warn "Variante i686 no disponible/instalable en este sistema, se omite (no es crítico)"
        log_ok "Códecs AMD (mesa-va-drivers-freeworld) instalados"
    fi

    if $has_nvidia; then
        log_info "GPU NVIDIA detectada → instalando códecs VAAPI"
        sudo dnf install -y libva-nvidia-driver
        log_ok "Códecs NVIDIA (libva-nvidia-driver) instalados"

        echo
        log_warn "El driver propietario NVIDIA (akmod-nvidia) compila un módulo de kernel."
        log_warn "Si tenés Secure Boot ACTIVADO, hay un paso manual de firma (MOK enrollment)"
        log_warn "que este script NO hace por vos — está documentado en MANUAL.md."
        if ask_yes_no "¿Instalar el driver propietario NVIDIA (akmod-nvidia)?"; then
            sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda
            log_ok "akmod-nvidia instalado. El módulo se compila en segundo plano; se recomienda reiniciar."
        else
            log_info "Se omite la instalación de akmod-nvidia (podés instalarlo más tarde manualmente)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 5. Brave + swappiness
# ---------------------------------------------------------------------------
step_brave_and_swappiness() {
    log_step "5/8 · Instalando Brave y ajustando swappiness"

    if command -v brave-browser &>/dev/null; then
        log_ok "Brave ya está instalado"
    else
        curl -fsS https://dl.brave.com/install.sh | sh
        log_ok "Brave instalado (flavor origin)"
    fi

    local sysctl_file="/etc/sysctl.d/99-swappiness.conf"
    echo "vm.swappiness=150" | sudo tee "$sysctl_file" >/dev/null
    sudo sysctl --system >/dev/null
    log_ok "vm.swappiness=150 aplicado (${sysctl_file})"
}

# ---------------------------------------------------------------------------
# 6. Flatpak: quitar remoto de Fedora, dejar solo Flathub
# ---------------------------------------------------------------------------
step_flatpak_flathub() {
    log_step "6/8 · Configurando Flatpak (solo Flathub)"

    if flatpak remote-list | grep -qw "^fedora"; then
        flatpak remote-delete fedora --force
        log_ok "Remoto 'fedora' de Flatpak eliminado"
    else
        log_ok "El remoto 'fedora' ya no estaba presente"
    fi

    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    log_ok "Flathub configurado como único remoto Flatpak"
}

# ---------------------------------------------------------------------------
# 7. ASUS (opcional, solo si se detecta hardware ASUS)
# ---------------------------------------------------------------------------
step_asus_tools() {
    log_step "7/8 · Detectando hardware ASUS"

    local vendor
    vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")"

    if [[ "$vendor" != *ASUS* ]]; then
        log_info "No se detectó hardware ASUS (fabricante detectado: '${vendor:-desconocido}'). Se omite este bloque."
        return
    fi

    log_info "Hardware ASUS detectado (${vendor})"
    if ! ask_yes_no "¿Instalar herramientas ASUS Linux (asusctl + repo Terra)?"; then
        log_info "Se omiten las herramientas ASUS a pedido del usuario"
        return
    fi

    if ! pkg_installed terra-release; then
        sudo dnf install -y --nogpgcheck \
            --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
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

    echo
    log_warn "Cardwire (reemplazo de supergfxd para gráficos híbridos) es EXPERIMENTAL"
    log_warn "todavía tiene 'rough edges' según sus propios desarrolladores."
    if ask_yes_no "¿Instalar Cardwire de todas formas?"; then
        sudo dnf install -y cardwire
        log_ok "Cardwire instalado (recordá que es experimental)"
    else
        log_info "Se omite Cardwire"
    fi
}

# ---------------------------------------------------------------------------
# 8. Resumen final
# ---------------------------------------------------------------------------
step_summary() {
    log_step "8/8 · Resumen"
    echo "Instalación/configuración completa."
    echo "Recomendaciones:"
    echo "  - Reiniciá el equipo, sobre todo si instalaste akmod-nvidia."
    echo "  - Si tenés Secure Boot activado y usaste akmod-nvidia, revisá MANUAL.md"
    echo "    para el paso de MOK enrollment (obligatorio, se hace en el próximo arranque)."
    echo "  - Para quitar apps de KDE que no uses, corré cleanup-fedora-plasma.sh por separado."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    require_root_privileges
    step_base_update
    step_rpmfusion_multimedia
    step_cpu_microcode
    step_gpu_drivers
    step_brave_and_swappiness
    step_flatpak_flathub
    step_asus_tools
    step_summary
}

main "$@"
