#!/usr/bin/env bash
#
# setup-fedora-plasma.sh
#
# Script base de configuración inicial para Fedora KDE Plasma. Deja el equipo
# listo con configuración general, multimedia, códecs por hardware (AMD/Intel),
# microcódigo de CPU y Flathub. NVIDIA y ASUS son componentes independientes.
#
# Uso:
#   chmod +x setup-fedora-plasma.sh
#   ./setup-fedora-plasma.sh
#
# Opcional (primeros días de una versión nueva de Fedora, cuando RPM Fusion
# va por delante de los repos de Fedora y freeworld no se puede instalar):
#   MESA_FROM_TESTING=1 ./setup-fedora-plasma.sh
#
# Repite ejecución: el script está diseñado para poder ejecutarse varias veces sin
# romper configuraciones existentes; cada paso comprueba el estado cuando corresponde.
#
# Avisos y fallos:
#   aviso  algo opcional o informativo no se pudo hacer (no cambia el resultado).
#   fallo  algo que el script debía dejar instalado o configurado no quedó así.
#
# Códigos de salida:
#   0  correcto, con o sin avisos
#   1  hubo al menos un fallo (se listan en el resumen final), o el sistema no
#      es Fedora con KDE Plasma

set -uo pipefail

# ---------------------------------------------------------------------------
# Utilidades de salida
# ---------------------------------------------------------------------------
COLOR_RESET="\e[0m"
COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_BLUE="\e[34m"

# Avisos y fallos se acumulan aquí para mostrarlos en el resumen final.
WARNINGS=()
FAILURES=()

# Los rellena detect_gpu_vendors (paso 4) según las GPU presentes.
GPU_AMD=false
GPU_INTEL=false
GPU_NVIDIA=false

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; WARNINGS+=("$*"); }
log_err()   { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"; }
log_step()  { echo -e "\n${COLOR_BLUE}==>${COLOR_RESET} \e[1m$*${COLOR_RESET}"; }

# Fallo real: se muestra y se acumula; el script termina con código 1.
record_fail() { log_err "$*"; FAILURES+=("$*"); }

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
    log_info "Fedora ${VERSION_ID:-?} detectado"
}

require_root_privileges() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_err "No corras este script directamente como root. Ejecútalo como tu usuario normal; se te pedirá la contraseña de sudo cuando haga falta."
        exit 1
    fi
    if ! command -v sudo &>/dev/null; then
        log_err "No se encontró 'sudo'. Instálalo o corre este script con un método equivalente."
        exit 1
    fi
    # Fuerza a pedir la contraseña una sola vez al principio
    sudo -v
}

pkg_installed() {
    rpm -q "$1" &>/dev/null
}

# Este proyecto es solo para Fedora con KDE Plasma. Se comprueba por paquete (no por
# XDG_CURRENT_DESKTOP) para que funcione también por SSH o desde la GUI.
require_plasma() {
    if ! pkg_installed plasma-desktop; then
        log_err "No se encontró plasma-desktop. Este script es exclusivo para Fedora KDE Plasma."
        exit 1
    fi
}

# Instala un paquete y VERIFICA con rpm -q que quedó instalado.
# No depende solo del código de salida de dnf.
# Uso: install_verified <paquete> [opciones extra de dnf...]   (si falla: fallo)
#      install_optional <paquete> [opciones extra de dnf...]   (si falla: aviso)
_install_checked() {
    local severity="$1" pkg="$2"
    shift 2
    if pkg_installed "$pkg"; then
        log_ok "$pkg ya estaba instalado"
        return 0
    fi
    sudo dnf install -y "$@" "$pkg"
    if pkg_installed "$pkg"; then
        log_ok "$pkg instalado"
        return 0
    fi
    if [[ "$severity" == "fail" ]]; then
        record_fail "No se pudo instalar $pkg."
    else
        log_warn "No se pudo instalar $pkg (opcional)."
    fi
    return 1
}

install_verified() { _install_checked fail "$@"; }
install_optional() { _install_checked warn "$@"; }

configure_dnf_performance() {
    local dnf_conf="/etc/dnf/dnf.conf"

    if ! grep -qE '^[[:space:]]*max_parallel_downloads=' "$dnf_conf" 2>/dev/null; then
        echo "max_parallel_downloads=10" | sudo tee -a "$dnf_conf" >/dev/null
        log_ok "dnf configurado con max_parallel_downloads=10 (${dnf_conf})"
    else
        log_ok "dnf ya tenía max_parallel_downloads configurado"
    fi
}

# Versiones anteriores de este script fijaban vm.swappiness=60, lo que pisa el
# ajuste que Fedora ya trae para zram. Si el archivo lo creó este script, se retira.
remove_legacy_swappiness() {
    local sysctl_file="/etc/sysctl.d/99-swappiness.conf"
    local marker="gestionada por setup-fedora-plasma.sh"

    [[ -f "$sysctl_file" ]] || return 0
    if grep -qF "$marker" "$sysctl_file"; then
        if sudo rm -f "$sysctl_file"; then
            log_ok "Eliminado ${sysctl_file} (creado por una versión anterior); se aplicará el valor por defecto de Fedora tras reiniciar"
        else
            log_warn "No se pudo eliminar ${sysctl_file}."
        fi
    else
        log_info "${sysctl_file} existe pero no es de este script; se conserva."
    fi
}

# ---------------------------------------------------------------------------
# 1. Base del sistema
# ---------------------------------------------------------------------------
step_base_update() {
    log_step "1/5 · Actualizando el sistema e instalando paquetes base"

    configure_dnf_performance
    remove_legacy_swappiness

    if ! sudo dnf upgrade --refresh -y; then
        record_fail "dnf upgrade --refresh falló; la actualización del sistema no quedó confirmada (el script continúa)."
    else
        log_ok "Sistema actualizado correctamente"
    fi

    # p7zip fue retirado de Fedora; el paquete actual es 7zip.
    # unrar está en RPM Fusion nonfree, así que se instala en el paso 2.
    local pkg
    for pkg in fastfetch 7zip; do
        install_verified "$pkg" || true
    done

    # Opcionales: solo se instalan si existen en los repos activos.
    for pkg in 7zip-plugins papirus-icon-theme; do
        if pkg_installed "$pkg"; then
            log_ok "$pkg ya estaba instalado"
        elif [[ -n "$(dnf repoquery --available --qf '%{name}' "$pkg" 2>/dev/null)" ]]; then
            install_optional "$pkg" || true
        else
            log_info "$pkg no existe en los repositorios activos; se omite (opcional)."
        fi
    done
}

# ---------------------------------------------------------------------------
# 2. RPM Fusion + multimedia
# ---------------------------------------------------------------------------
install_multimedia_group() {
    # El ID del grupo ha cambiado entre versiones de Fedora/dnf5, así que se
    # prueban varios nombres en orden.
    local candidates=(multimedia sound-and-video Multimedia)
    local g
    for g in "${candidates[@]}"; do
        if sudo dnf group install -y "$g" \
            --setopt="install_weak_deps=False" \
            --exclude=PackageKit-gstreamer-plugin; then
            log_ok "Grupo '$g' instalado"
            return 0
        fi
    done
    record_fail "No se pudo instalar ningún grupo multimedia (probados: ${candidates[*]}). Mira el nombre actual con: dnf group list --hidden | grep -i -E 'multimedia|sound'"
    return 1
}

step_rpmfusion_multimedia() {
    log_step "2/5 · Habilitando RPM Fusion y configurando multimedia"

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
    if pkg_installed rpmfusion-free-release && pkg_installed rpmfusion-nonfree-release; then
        log_ok "RPM Fusion (free + nonfree) habilitado"
    else
        record_fail "RPM Fusion no quedó instalado por completo (free o nonfree falta); se omiten unrar, ffmpeg completo y el grupo multimedia."
        return 1
    fi

    if ! sudo dnf update @core -y; then
        record_fail "dnf update @core falló."
    fi

    if ! sudo dnf install -y rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data; then
        log_warn "No se pudieron instalar los datos AppStream de RPM Fusion (solo afectan a la tienda de software)."
    fi

    install_verified unrar || true

    # Swap de ffmpeg-free por ffmpeg completo
    if pkg_installed ffmpeg-free; then
        sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
    elif ! pkg_installed ffmpeg; then
        sudo dnf install -y ffmpeg
    fi
    if pkg_installed ffmpeg && ! pkg_installed ffmpeg-free; then
        log_ok "ffmpeg completo instalado"
    else
        record_fail "ffmpeg completo no quedó instalado correctamente (ffmpeg-free sigue presente o falta ffmpeg)."
    fi

    install_multimedia_group || true
}

# ---------------------------------------------------------------------------
# 3. Microcódigo de CPU (detección automática Intel/AMD)
# ---------------------------------------------------------------------------
step_cpu_microcode() {
    log_step "3/5 · Detectando CPU e instalando microcódigo"

    local vendor
    vendor="$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $NF}')"

    case "$vendor" in
        GenuineIntel)
            log_info "CPU Intel detectada"
            install_verified microcode_ctl || true
            ;;
        AuthenticAMD)
            log_info "CPU AMD detectada"
            # En Fedora el microcódigo AMD viene dentro de linux-firmware,
            # no como paquete separado (a diferencia de Debian con amd64-microcode).
            install_verified linux-firmware || true
            ;;
        *)
            log_warn "No se pudo determinar el fabricante de la CPU (vendor_id='${vendor}'). Se omite este paso."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 4. GPU: códecs por hardware (AMD, Intel o NVIDIA; también equipos híbridos)
# ---------------------------------------------------------------------------
# Clasifica las GPU a partir de la salida de 'lspci -nn' usando la clase PCI
# (03xx = controlador de pantalla) y el ID de fabricante (AMD/ATI=1002,
# NVIDIA=10de, Intel=8086). No depende del texto del nombre del dispositivo.
detect_gpu_vendors() {
    local gpus
    GPU_AMD=false
    GPU_INTEL=false
    GPU_NVIDIA=false

    gpus="$(grep -iE '\[03[0-9a-f]{2}\]' <<<"$1")"
    grep -qiE '\[1002:[0-9a-f]{4}\]' <<<"$gpus" && GPU_AMD=true
    grep -qiE '\[8086:[0-9a-f]{4}\]' <<<"$gpus" && GPU_INTEL=true
    grep -qiE '\[10de:[0-9a-f]{4}\]' <<<"$gpus" && GPU_NVIDIA=true
    return 0
}

freeworld_hint() {
    log_info "Si el error menciona mesa-filesystem, RPM Fusion va por delante de Fedora (pasa en los primeros días de una versión nueva)."
    log_info "Opciones: reintentar en 1-2 días, o ejecutar el script con MESA_FROM_TESTING=1 para traer Mesa desde updates-testing."
}

install_amd_codecs() {
    log_info "GPU AMD detectada → instalando códecs VAAPI"

    # Opcional: traer Mesa desde updates-testing para alinearla con RPM Fusion.
    if [[ "${MESA_FROM_TESTING:-0}" == "1" ]]; then
        log_info "MESA_FROM_TESTING=1 → actualizando Mesa desde updates-testing"
        sudo dnf upgrade -y --enablerepo=updates-testing 'mesa-*' \
            || log_warn "No se pudo actualizar Mesa desde updates-testing."
    fi

    # mesa-va-drivers-freeworld sustituye a mesa-va-drivers, por eso --allowerasing.
    if ! install_verified mesa-va-drivers-freeworld --allowerasing; then
        freeworld_hint
        return 1
    fi

    # Variante i686 (Steam, Wine 32 bits). No es crítica.
    if ! install_optional mesa-va-drivers-freeworld.i686 --allowerasing; then
        log_info "La variante i686 solo hace falta para aplicaciones de 32 bits (Steam/Wine)."
    fi
    return 0
}

install_intel_codecs() {
    log_info "GPU Intel detectada → instalando intel-media-driver (VA-API)"
    if install_verified intel-media-driver; then
        return 0
    fi
    log_info "En GPU Intel muy antiguas puede hacer falta libva-intel-driver en lugar de intel-media-driver."
    return 1
}

verify_vaapi() {
    # vainfo sirve para comprobar H.264/HEVC por hardware.
    install_optional libva-utils || true

    if ! command -v vainfo &>/dev/null; then
        log_info "vainfo no está instalado (paquete libva-utils); no se pudo verificar H.264/HEVC."
        return 0
    fi
    # Se captura la salida antes de filtrarla: con 'pipefail', 'vainfo | grep -q'
    # puede dar un falso error si grep cierra la tubería antes de que vainfo termine.
    local out
    out="$(vainfo 2>/dev/null)"
    if grep -qiE 'H264|HEVC' <<<"$out"; then
        log_ok "VA-API expone H.264/HEVC por hardware"
    else
        log_warn "Los códecs están instalados pero vainfo no muestra H.264/HEVC. Reinicia la sesión y vuelve a comprobar."
    fi
}

step_gpu_codecs() {
    log_step "4/5 · Detectando GPU e instalando códecs por hardware"

    if ! command -v lspci &>/dev/null; then
        log_warn "lspci no está instalado (paquete pciutils); no se puede detectar la GPU. Se omite este paso."
        return 0
    fi

    detect_gpu_vendors "$(lspci -nn 2>/dev/null)"

    if ! $GPU_AMD && ! $GPU_INTEL && ! $GPU_NVIDIA; then
        log_info "No se detectó una GPU AMD, Intel ni NVIDIA (¿máquina virtual?). Se omite este paso."
        return 0
    fi

    # Las tres comprobaciones son independientes: un portátil híbrido
    # (Intel+NVIDIA o AMD+NVIDIA) recibe los pasos de cada GPU que tenga.
    local vaapi_ok=false

    if $GPU_NVIDIA; then
        log_info "GPU NVIDIA detectada. Sus componentes se gestionan desde nvidia/setup-nvidia.sh."
    fi
    if $GPU_INTEL; then
        install_intel_codecs && vaapi_ok=true
    fi
    if $GPU_AMD; then
        install_amd_codecs && vaapi_ok=true
    fi
    if $vaapi_ok; then
        verify_vaapi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 5. Flatpak: quitar remoto de Fedora, dejar solo Flathub
# ---------------------------------------------------------------------------
step_flatpak_flathub() {
    log_step "5/5 · Configurando Flatpak (solo Flathub)"

    if ! command -v flatpak &>/dev/null; then
        record_fail "Flatpak no está instalado; no se puede configurar Flathub."
        return
    fi

    # 'remote-list' separa columnas con tabuladores; se pide solo la columna name.
    if flatpak remotes --columns=name | grep -qx 'fedora'; then
        if flatpak remote-delete fedora --force; then
            log_ok "Remoto 'fedora' de Flatpak eliminado"
        else
            log_warn "No se pudo eliminar el remoto 'fedora' de Flatpak."
        fi
    else
        log_ok "El remoto 'fedora' ya no estaba presente"
    fi

    if flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
        log_ok "Flathub configurado como remoto Flatpak"
    else
        record_fail "No se pudo configurar Flathub."
    fi
}

# ---------------------------------------------------------------------------
# Resumen final (comprueba el estado real, no solo códigos de salida)
# ---------------------------------------------------------------------------
step_summary() {
    log_step "Resumen final"
    echo "Estado de componentes principales:"

    local pkg
    local summary_pkgs=(fastfetch unrar 7zip)
    for pkg in "${summary_pkgs[@]}"; do
        if pkg_installed "$pkg"; then
            echo "  - $pkg: instalado"
        else
            echo "  - $pkg: NO instalado"
        fi
    done

    if pkg_installed ffmpeg && ! pkg_installed ffmpeg-free; then
        echo "  - ffmpeg: completo instalado"
    else
        echo "  - ffmpeg: NO es la versión completa"
    fi

    if $GPU_AMD; then
        if pkg_installed mesa-va-drivers-freeworld; then
            echo "  - mesa-va-drivers-freeworld: instalado"
        else
            echo "  - mesa-va-drivers-freeworld: NO instalado (sin H.264/HEVC por hardware)"
        fi
    fi

    if $GPU_INTEL; then
        if pkg_installed intel-media-driver; then
            echo "  - intel-media-driver: instalado"
        else
            echo "  - intel-media-driver: NO instalado (sin H.264/HEVC por hardware)"
        fi
    fi

    if command -v flatpak &>/dev/null && flatpak remotes --columns=name | grep -qx 'flathub'; then
        echo "  - Flathub: configurado"
    else
        echo "  - Flathub: no confirmado"
    fi

    echo "Recomendaciones:"
    echo "  - Para NVIDIA, ejecuta nvidia/setup-nvidia.sh por separado."
    echo "  - Para ASUS/ROG, ejecuta asus/setup-asusctl.sh por separado."
    echo "  - Para quitar apps de KDE que no uses, corre cleanup-fedora-plasma.sh por separado."
    echo "  - Reinicia el equipo si instalaste componentes que lo requieran."

    local w f
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo
        echo -e "${COLOR_YELLOW}Avisos (${#WARNINGS[@]}):${COLOR_RESET}"
        for w in "${WARNINGS[@]}"; do
            echo "  - $w"
        done
    fi

    echo
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        echo -e "${COLOR_RED}El script terminó con ${#FAILURES[@]} fallo(s):${COLOR_RESET}"
        for f in "${FAILURES[@]}"; do
            echo "  - $f"
        done
        return 1
    fi

    if [[ ${#WARNINGS[@]} -eq 0 ]]; then
        log_ok "El script terminó sin errores ni avisos."
    else
        log_ok "El script terminó sin errores (solo avisos)."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    require_fedora
    require_root_privileges
    require_plasma
    step_base_update
    step_rpmfusion_multimedia
    step_cpu_microcode
    step_gpu_codecs
    step_flatpak_flathub
    step_summary

    # Código de salida 1 si hubo fallos reales (los avisos no cuentan).
    return $?
}

# Solo ejecuta main si el archivo se lanza directamente (no si se hace 'source').
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi