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

# Fallos acumulados durante la ejecución; se listan en el resumen final.
FAILURES=()
record_fail() {
    FAILURES+=("$1")
    log_err "$1"
}

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

# Igual que pkg_installed, pero también acepta capacidades virtuales (Provides).
# Se usa solo para p7zip/p7zip-plugins: en Fedora 45 ya no son paquetes reales,
# los proveen 7zip / 7zip-standalone, y 'rpm -q p7zip' (solo por nombre) falla.
cap_installed() {
    rpm -q --whatprovides "$1" &>/dev/null
}

configure_dnf_performance() {
    local dnf_conf="/etc/dnf/dnf.conf"

    if ! grep -qE '^[[:space:]]*max_parallel_downloads=' "$dnf_conf" 2>/dev/null; then
        echo "max_parallel_downloads=10" | sudo tee -a "$dnf_conf" >/dev/null
        log_ok "dnf configurado con max_parallel_downloads=10 (${dnf_conf})"
    else
        log_ok "dnf ya tenía max_parallel_downloads configurado"
    fi
}

# ---------------------------------------------------------------------------
# 1. Base del sistema
# ---------------------------------------------------------------------------
step_base_update() {
    log_step "1/6 · Actualizando el sistema e instalando paquetes base"

    configure_dnf_performance

    if ! sudo dnf upgrade --refresh -y; then
        record_fail "dnf upgrade --refresh falló; la actualización del sistema no quedó confirmada (el script continúa)."
    else
        log_ok "Sistema actualizado correctamente"
    fi

    # p7zip y p7zip-plugins se mantienen por nombre: en Fedora 44 son paquetes reales y en
    # Fedora 45 dnf los resuelve por Provides hacia 7zip / 7zip-standalone.
    local base_pkgs=(fastfetch unrar p7zip p7zip-plugins papirus-icon-theme)
    local to_install=()
    for pkg in "${base_pkgs[@]}"; do
        cap_installed "$pkg" || to_install+=("$pkg")
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        if sudo dnf install -y "${to_install[@]}"; then
            log_ok "Paquetes base instalados: ${to_install[*]}"
        else
            record_fail "No se pudieron instalar los paquetes base: ${to_install[*]}"
        fi
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

    local rpmfusion_ok=true
    if ! pkg_installed rpmfusion-free-release; then
        if ! sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_ver}.noarch.rpm"; then
            record_fail "No se pudo instalar rpmfusion-free-release."
            rpmfusion_ok=false
        fi
    fi
    if ! pkg_installed rpmfusion-nonfree-release; then
        if ! sudo dnf install -y \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_ver}.noarch.rpm"; then
            record_fail "No se pudo instalar rpmfusion-nonfree-release."
            rpmfusion_ok=false
        fi
    fi
    if ! $rpmfusion_ok; then
        log_warn "RPM Fusion no quedó habilitado; se omiten los pasos multimedia que dependen de él."
        return
    fi
    log_ok "RPM Fusion (free + nonfree) habilitado"

    if ! sudo dnf update @core -y; then
        record_fail "dnf update @core falló."
    fi

    if ! sudo dnf install -y rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data; then
        record_fail "No se pudieron instalar los datos AppStream de RPM Fusion."
    fi

    # Swap de ffmpeg-free por ffmpeg completo
    if pkg_installed ffmpeg-free; then
        if sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing; then
            log_ok "ffmpeg-free reemplazado por ffmpeg completo"
        else
            record_fail "No se pudo reemplazar ffmpeg-free por ffmpeg."
        fi
    elif pkg_installed ffmpeg; then
        log_ok "ffmpeg completo ya estaba instalado"
    else
        if ! sudo dnf install -y ffmpeg; then
            record_fail "No se pudo instalar ffmpeg."
        fi
    fi

    # Grupo multimedia, excluyendo PackageKit-gstreamer-plugin.
    # Es un grupo oculto: se referencia por su id (minúsculas), no por el nombre "Multimedia".
    if sudo dnf group install -y multimedia \
        --setopt="install_weak_deps=False" \
        --exclude=PackageKit-gstreamer-plugin; then
        log_ok "Grupo Multimedia instalado"
    else
        record_fail "No se pudo instalar el grupo multimedia (el script continúa)."
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
                if sudo dnf install -y microcode_ctl; then
                    log_ok "microcode_ctl instalado (microcódigo Intel)"
                else
                    record_fail "No se pudo instalar microcode_ctl."
                fi
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
                record_fail "No se pudo instalar linux-firmware; no se completó el microcódigo AMD."
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

    # Detección por vendor ID PCI (1002=AMD/ATI, 10de=NVIDIA, 8086=Intel).
    # No se busca por texto: 'ati' aparece en "compatible" y "Corporation".
    local gpu_info
    gpu_info="$(lspci -nn 2>/dev/null | grep -E 'VGA compatible controller|3D controller|Display controller')"

    local has_amd=false
    local has_nvidia=false
    local has_intel=false
    grep -q '\[1002:' <<<"$gpu_info" && has_amd=true
    grep -q '\[10de:' <<<"$gpu_info" && has_nvidia=true
    grep -q '\[8086:' <<<"$gpu_info" && has_intel=true

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
    if ! sudo dnf install -y mesa-va-drivers-freeworld; then
        record_fail "No se pudo instalar mesa-va-drivers-freeworld. Suele deberse a un desfase de versión de Mesa entre Fedora y RPM Fusion; reintenta cuando ambos repos se sincronicen."
        return
    fi
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
    log_ok "Códecs AMD (mesa-va-drivers-freeworld) configurados"
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
        local check=pkg_installed
        [[ "$pkg" == p7zip || "$pkg" == p7zip-plugins ]] && check=cap_installed
        if "$check" "$pkg"; then
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

    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        echo
        log_err "El script terminó con ${#FAILURES[@]} fallo(s):"
        local f
        for f in "${FAILURES[@]}"; do
            echo "  - $f"
        done
        return 1
    fi
    log_ok "El script terminó sin errores."
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