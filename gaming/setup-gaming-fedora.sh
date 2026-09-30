#!/usr/bin/env bash
#
# setup-gaming-fedora.sh
#
# Instala y optimiza Fedora Workstation / KDE Plasma para jugar: Steam,
# ProtonPlus (gestor de builds de Proton-GE), Heroic Games Launcher (con
# auto-actualización desde GitHub), GameMode, MangoHud, GOverlay, y algunos
# ajustes del sistema recomendados para juegos modernos.
#
# Uso:
#   chmod +x setup-gaming-fedora.sh
#   ./setup-gaming-fedora.sh
#
# Complementario a setup-fedora-plasma.sh (asume que RPM Fusion puede no estar
# habilitado todavía, y lo habilita si hace falta).
# Repite ejecución: el script es idempotente.

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
    sudo -v
}

pkg_installed() {
    rpm -q "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# 1. RPM Fusion (necesario para Steam)
# ---------------------------------------------------------------------------
step_ensure_rpmfusion() {
    log_step "1/9 · Comprobando RPM Fusion (necesario para Steam)"

    if pkg_installed rpmfusion-free-release && pkg_installed rpmfusion-nonfree-release; then
        log_ok "RPM Fusion (free + nonfree) ya estaba habilitado, se omite este paso"
        return
    fi

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
}

# ---------------------------------------------------------------------------
# 2. Steam
# ---------------------------------------------------------------------------
step_steam() {
    log_step "2/9 · Instalando Steam"

    if pkg_installed steam; then
        log_ok "Steam ya estaba instalado"
    else
        sudo dnf install -y steam
        log_ok "Steam instalado"
    fi
}

# ---------------------------------------------------------------------------
# 3. ProtonPlus (vía COPR wehagy/protonplus)
# ---------------------------------------------------------------------------
step_protonplus() {
    log_step "3/9 · Instalando ProtonPlus"

    if ! dnf copr list 2>/dev/null | grep -qi 'wehagy/protonplus'; then
        sudo dnf copr enable -y wehagy/protonplus
        log_ok "Repo COPR wehagy/protonplus habilitado"
    else
        log_ok "Repo COPR wehagy/protonplus ya estaba habilitado"
    fi

    if pkg_installed protonplus; then
        log_ok "ProtonPlus ya estaba instalado"
    else
        sudo dnf install -y protonplus
        log_ok "ProtonPlus instalado"
    fi
}

# ---------------------------------------------------------------------------
# 4. Heroic Games Launcher (descarga automática del último .rpm de GitHub)
# ---------------------------------------------------------------------------
step_heroic_launcher() {
    log_step "4/9 · Descargando e instalando/actualizando Heroic Games Launcher"

    local api_url="https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest"
    local rpm_url

    if ! command -v curl &>/dev/null; then
        sudo dnf install -y curl
    fi
    rpm_url="$(curl -fsSL "$api_url" | grep -oP '"browser_download_url":\s*"\K[^"]*linux-x86_64\.rpm(?=")' | head -n1)"

    if [[ -z "$rpm_url" ]]; then
        log_err "No se pudo obtener la URL del último .rpm de Heroic desde GitHub. Se omite este paso."
        return
    fi

    local latest_version
    latest_version="$(echo "$rpm_url" | grep -oP 'Heroic-\K[0-9.]+(?=-linux)')"

    if pkg_installed heroic && [[ -n "$latest_version" ]]; then
        local installed_version
        installed_version="$(rpm -q --qf '%{VERSION}' heroic 2>/dev/null)"
        if [[ "$installed_version" == "$latest_version" ]]; then
            log_ok "Heroic Games Launcher ya está en la última versión (${installed_version})"
            return
        fi
    fi

    local tmp_file
    tmp_file="$(mktemp --suffix=.rpm)"
    log_info "Descargando: ${rpm_url}"
    curl -fsSL "$rpm_url" -o "$tmp_file"

    sudo dnf install -y "$tmp_file"
    rm -f "$tmp_file"
    log_ok "Heroic Games Launcher instalado/actualizado (versión ${latest_version:-desconocida})"
}

# ---------------------------------------------------------------------------
# 5. GameMode + MangoHud + GOverlay
# ---------------------------------------------------------------------------
step_gamemode_mangohud() {
    log_step "5/9 · Instalando GameMode, MangoHud y GOverlay"

    local packages=(gamemode mangohud goverlay)
    local package
    for package in "${packages[@]}"; do
        if pkg_installed "$package"; then
            log_ok "$package ya estaba instalado"
        else
            sudo dnf install -y "$package"
            log_ok "$package instalado"
        fi
    done
    log_info "Para usarlos, en las opciones de lanzamiento de un juego en Steam poné:"
    log_info "  gamemoderun mangohud %command%"
    log_info "Podés configurar el overlay de MangoHud gráficamente abriendo GOverlay."
}

# ---------------------------------------------------------------------------
# 6. Configuración de GameMode
# ---------------------------------------------------------------------------
step_gamemode_config() {
    log_step "6/9 · Configurando GameMode"

    local config_file="/etc/gamemode.ini"

    if command -v gamemoded &>/dev/null; then
        log_ok "GameMode está instalado"
    else
        log_warn "No se encontró gamemoded después de instalar GameMode."
        return
    fi

    if [[ ! -f "$config_file" ]]; then
        sudo tee "$config_file" >/dev/null <<'EOF'
[general]
renice=10
EOF
        log_ok "Creado ${config_file} con valores básicos de GameMode"
    else
        log_ok "${config_file} ya existe; no se sobrescribe la configuración del usuario"
    fi

    if gamemoded -t &>/dev/null; then
        log_ok "La prueba de GameMode terminó correctamente"
    else
        log_warn "GameMode está instalado, pero la prueba gamemoded -t no terminó correctamente"
    fi
}

# ---------------------------------------------------------------------------
# 7. game-performance: wrapper temporal de rendimiento
# ---------------------------------------------------------------------------
step_game_performance() {
    log_step "7/9 · Instalando game-performance"

    local target="/usr/local/bin/game-performance"

    sudo tee "$target" >/dev/null <<'EOF'
#!/usr/bin/env bash
# game-performance — gestionado por setup-gaming-fedora.sh
set -uo pipefail

if [[ $# -eq 0 ]]; then
    echo "Uso: game-performance <comando> [argumentos...]"
    echo "Ejemplo: game-performance gamemoderun mangohud %command%"
    exit 2
fi

if ! command -v systemd-inhibit &>/dev/null; then
    echo "Error: systemd-inhibit no está disponible." >&2
    exit 1
fi

previous_profile=""
if command -v powerprofilesctl &>/dev/null; then
    previous_profile="$(powerprofilesctl get 2>/dev/null || true)"
fi

restore_profile() {
    if [[ -n "$previous_profile" ]] && command -v powerprofilesctl &>/dev/null; then
        powerprofilesctl set "$previous_profile" >/dev/null 2>&1 || true
    fi
}
trap restore_profile EXIT INT TERM

if command -v powerprofilesctl &>/dev/null; then
    if powerprofilesctl list 2>/dev/null | grep -qE 'performance'; then
        powerprofilesctl set performance >/dev/null 2>&1 || true
    fi
fi

exec systemd-inhibit \
    --what=idle:sleep \
    --why="Juego en ejecución mediante game-performance" \
    --mode=block \
    "$@"
EOF

    sudo chmod 0755 "$target"

    if [[ -x "$target" ]]; then
        log_ok "Instalado ${target}"
        log_info "Uso: game-performance gamemoderun mangohud %command%"
        log_info "El perfil de energía se cambia temporalmente y se restaura al terminar."
    else
        log_warn "No se pudo verificar ${target}"
    fi
}

# ---------------------------------------------------------------------------
# 8. vm.max_map_count elevado
# ---------------------------------------------------------------------------
step_max_map_count() {
    log_step "8/9 · Ajustando vm.max_map_count"

    local sysctl_file="/etc/sysctl.d/80-gamecompatibility.conf"
    if [[ -f "$sysctl_file" ]] && grep -q '^vm.max_map_count=2147483642' "$sysctl_file"; then
        log_ok "vm.max_map_count ya estaba configurado"
    else
        echo "vm.max_map_count=2147483642" | sudo tee "$sysctl_file" >/dev/null
        sudo sysctl --system >/dev/null
        log_ok "vm.max_map_count=2147483642 aplicado (${sysctl_file})"
    fi
}

# ---------------------------------------------------------------------------
# 9. Verificar/activar ntsync
# ---------------------------------------------------------------------------
step_ntsync() {
    log_step "9/9 · Verificando soporte de ntsync"

    local modules_file="/etc/modules-load.d/ntsync.conf"

    if [[ -e /sys/module/ntsync ]]; then
        log_ok "El módulo ntsync ya está cargado"
    elif [[ -x /usr/sbin/modinfo ]] && /usr/sbin/modinfo ntsync &>/dev/null; then
        if sudo modprobe ntsync; then
            log_ok "Módulo ntsync cargado correctamente"
        else
            log_warn "El módulo ntsync existe, pero no se pudo cargar."
            return
        fi
    else
        log_warn "Tu kernel no trae el módulo ntsync (se incorporó a partir del kernel 6.14)."
        log_warn "Actualizá el kernel si querés esta mejora de sincronización para Proton."
        return
    fi

    if [[ -e /dev/ntsync ]] && [[ -c /dev/ntsync ]]; then
        log_ok "El dispositivo /dev/ntsync está disponible para Wine/Proton"
    else
        log_warn "ntsync está cargado, pero /dev/ntsync no está disponible."
        return
    fi

    if [[ ! -f "$modules_file" ]]; then
        echo "ntsync" | sudo tee "$modules_file" >/dev/null
        log_ok "ntsync configurado para cargarse automáticamente en cada arranque"
    else
        log_ok "ntsync ya estaba configurado para cargarse automáticamente"
    fi
}

# ---------------------------------------------------------------------------
# Resumen final
# ---------------------------------------------------------------------------
step_summary() {
    log_step "Resumen"
    echo "Instalación/configuración de gaming completa."
    echo "Recomendaciones:"
    echo "  - Heroic Games Launcher se descarga e instala/actualiza automáticamente"
    echo "    desde el último .rpm publicado en GitHub cada vez que corrés este script."
    echo "  - En Steam: Configuración → Compatibilidad → activá 'Habilitar Steam Play"
    echo "    para todos los demás títulos' y elegí la versión de Proton (o una de"
    echo "    ProtonPlus) que quieras usar por defecto."
    echo "  - En las opciones de lanzamiento de cada juego: gamemoderun mangohud %command%"
    echo "  - Usá GOverlay si preferís configurar el overlay de MangoHud gráficamente"
    echo "    en vez de editar el archivo de configuración a mano."
    echo "  - Si querés rendimiento temporal durante un juego, usá:"
    echo "    game-performance gamemoderun mangohud %command%"
    echo "  - ntsync se considera operativo cuando el módulo está cargado y"
    echo "    /dev/ntsync está disponible para Wine/Proton; puede ser necesario reiniciar."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    require_fedora
    require_root_privileges
    step_ensure_rpmfusion
    step_steam
    step_protonplus
    step_heroic_launcher
    step_gamemode_mangohud
    step_gamemode_config
    step_game_performance
    step_max_map_count
    step_ntsync
    step_summary
}

main "$@"
