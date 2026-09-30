#!/usr/bin/env bash
#
# setup-fedora-plasma.sh
#
# Script de configuración inicial para Fedora Workstation / KDE Plasma spin.
# Deja el equipo listo con configuración general, multimedia, códecs AMD,
# microcódigo de CPU y Flathub. NVIDIA y ASUS son componentes independientes.
#
# Uso:
#   chmod +x setup-fedora-plasma.sh
#   ./setup-fedora-plasma.sh
#
# Repite ejecución: el script está diseñado para poder ejecutarse varias veces sin
# romper configuraciones existentes; cada paso comprueba el estado cuando corresponde.

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

require_fedora() {
    if [[ ! -r /etc/os-release ]]; then
        log_err "No se pudo leer /etc/os-release. No es posible verificar el sistema operativo."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "fedora" ]]; then
        log_err "Este script está diseñado para Fedora. Sistema detectado: ID=${ID:-desconocido}."
        exit 1
    fi
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

configure_dnf_performance() {
    local dnf_conf="/etc/dnf/dnf.conf"
    local changed=false

    if ! grep -qE '^[[:space:]]*max_parallel_downloads=' "$dnf_conf" 2>/dev/null; then
        echo "max_parallel_downloads=10" | sudo tee -a "$dnf_conf" >/dev/null
        changed=true
    fi

    if ! grep -qE '^[[:space:]]*fastestmirror=' "$dnf_conf" 2>/dev/null; then
        echo "fastestmirror=True" | sudo tee -a "$dnf_conf" >/dev/null
        changed=true
    fi

    if $changed; then
        log_ok "dnf configurado para descargas más rápidas (se añadieron las opciones que faltaban)"
    else
        log_ok "dnf ya tenía max_parallel_downloads y fastestmirror configurados"
    fi
}

# ---------------------------------------------------------------------------
# 1. Base del sistema
# ---------------------------------------------------------------------------
step_base_update() {
    log_step "1/6 · Actualizando el sistema e instalando paquetes base"

    configure_dnf_performance

    if ! sudo dnf upgrade --refresh -y; then
        log_warn "dnf upgrade --refresh falló. Se continúa con el resto del paso, pero la actualización del sistema no quedó confirmada."
    else
        log_ok "Sistema actualizado correctamente"
    fi

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
    log_step "2/6 · Habilitando RPM Fusion y configurando multimedia"

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
    if sudo dnf group install -y Multimedia \
        --setopt="install_weak_deps=False" \
        --exclude=PackageKit-gstreamer-plugin; then
        log_ok "Grupo Multimedia instalado"
    else
        log_warn "No se pudo instalar el grupo Multimedia. El resto del script continúa."
    fi
}

# ---------------------------------------------------------------------------
# 3. Microcódigo de CPU (detección automática Intel/AMD)
# ---------------------------------------------------------------------------
step_cpu_microcode() {
    log_step "3/6 · Detectando CPU e instalando microcódigo"

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
            if pkg_installed linux-firmware; then
                log_ok "linux-firmware ya estaba instalado (incluye microcódigo AMD)"
            elif sudo dnf install -y linux-firmware; then
                log_ok "linux-firmware instalado (incluye microcódigo AMD)"
            else
                log_warn "No se pudo instalar linux-firmware; no se pudo completar este paso para AMD."
            fi
            ;;
        *)
            log_warn "No se pudo determinar el fabricante de la CPU (vendor_id='${vendor}'). Se omite este paso."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 4. GPU: códecs AMD
# ---------------------------------------------------------------------------
step_gpu_codecs() {
    log_step "4/6 · Detectando GPU e instalando códecs por hardware"

    local gpu_info
    gpu_info="$(lspci -nnk | grep -iE 'vga|3d controller' -A2)"

    local has_amd=false
    local has_nvidia=false
    local has_intel=false
    echo "$gpu_info" | grep -qi 'amd\|ati' && has_amd=true
    echo "$gpu_info" | grep -qi 'nvidia' && has_nvidia=true
    echo "$gpu_info" | grep -qi 'intel' && has_intel=true

    if $has_amd; then
        log_info "GPU AMD detectada → instalando códecs VAAPI"
    elif $has_nvidia; then
        log_info "GPU NVIDIA detectada. Sus componentes se gestionan desde nvidia/setup-nvidia.sh."
        return
    elif $has_intel; then
        log_info "GPU Intel detectada. Este paso de códecs AMD no aplica."
        return
    else
        log_info "No se pudo identificar una GPU AMD, Intel o NVIDIA. Se omite este paso."
        return
    fi
    sudo dnf install -y mesa-va-drivers-freeworld
    if sudo dnf install -y mesa-va-drivers-freeworld.i686; then
        log_ok "Variante i686 de los códecs AMD instalada"
    else
        local i686_query
        local i686_rc
        i686_query="$(dnf repoquery --available --qf '%{name}' mesa-va-drivers-freeworld.i686 2>&1)"
        i686_rc=$?
        if [[ "$i686_rc" -ne 0 ]]; then
            log_warn "No se pudo comprobar la disponibilidad de mesa-va-drivers-freeworld.i686; se omite la variante i686."
        elif [[ -z "$i686_query" ]]; then
            log_warn "La variante i686 de mesa-va-drivers-freeworld no está disponible en los repositorios activos; se omite (no es crítico)."
        else
            log_warn "La instalación de mesa-va-drivers-freeworld.i686 falló aunque el paquete está disponible; se omite (no es crítico)."
        fi
    fi
    log_ok "Códecs AMD (mesa-va-drivers-freeworld) configurados
}

# ---------------------------------------------------------------------------
# 5. Swappiness
# ---------------------------------------------------------------------------
step_swappiness() {
    log_step "5/6 · Ajustando swappiness"

    local sysctl_file="/etc/sysctl.d/99-swappiness.conf"
    local marker="# Configuración de swappiness gestionada por setup-fedora-plasma.sh"

    # 60 coincide con el valor predeterminado habitual de Fedora y evita
    # forzar swap en disco sin que este script configure zram.
    # Si el usuario ya tiene este archivo, no se sobrescribe silenciosamente.
    if [[ -f "$sysctl_file" ]]; then
        if grep -qF "$marker" "$sysctl_file" && grep -qE '^vm\.swappiness=60$' "$sysctl_file"; then
            sudo sysctl --system >/dev/null
            log_ok "vm.swappiness=60 ya estaba configurado por este script"
        else
            log_warn "Ya existe ${sysctl_file} con contenido ajeno a este script; no se sobrescribe. Se conserva la configuración existente."
        fi
        return
    fi

    {
        echo "$marker"
        echo "vm.swappiness=60"
    } | sudo tee "$sysctl_file" >/dev/null
    sudo sysctl --system >/dev/null
    log_ok "vm.swappiness=60 aplicado (${sysctl_file})"
}

# ---------------------------------------------------------------------------
# 6. Flatpak: quitar remoto de Fedora, dejar solo Flathub
# ---------------------------------------------------------------------------
step_flatpak_flathub() {
    log_step "6/6 · Configurando Flatpak (solo Flathub)"

    if ! command -v flatpak &>/dev/null; then
        log_warn "Flatpak no está instalado; no se puede configurar Flathub."
        return
    fi

    if flatpak remote-list | grep -q '^fedora$'; then
        flatpak remote-delete fedora --force
        log_ok "Remoto 'fedora' de Flatpak eliminado"
    else
        log_ok "El remoto 'fedora' ya no estaba presente"
    fi

    if flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
        log_ok "Flathub configurado como único remoto Flatpak"
    else
        log_warn "No se pudo configurar Flathub."
    fi
}

# ---------------------------------------------------------------------------
# Resumen final
# ---------------------------------------------------------------------------
step_summary() {
    log_step "Resumen final"
    echo "Estado de componentes principales:"
    for pkg in fastfetch unrar p7zip p7zip-plugins papirus-icon-theme ffmpeg; do
        if pkg_installed "$pkg"; then
            echo "  - $pkg: instalado"
        else
            echo "  - $pkg: no instalado"
        fi
    done
    if command -v flatpak &>/dev/null && flatpak remote-list | grep -q '^flathub[[:space:]]'; then
        echo "  - Flathub: configurado"
    else
        echo "  - Flathub: no confirmado"
    fi
    echo "Recomendaciones:"
    echo "  - Para NVIDIA, ejecutá nvidia/setup-nvidia.sh por separado."
    echo "  - Para ASUS/ROG, ejecutá asus/setup-asusctl.sh por separado."
    echo "  - Reiniciá el equipo si instalaste componentes que lo requieran."
    echo "  - Para quitar apps de KDE que no uses, corré cleanup-fedora-plasma.sh por separado."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    require_fedora
    require_root_privileges
    step_base_update
    step_rpmfusion_multimedia
    step_cpu_microcode
    step_gpu_codecs
    step_swappiness
    step_flatpak_flathub
    step_summary
}

main "$@"
