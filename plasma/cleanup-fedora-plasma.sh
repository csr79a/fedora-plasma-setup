#!/usr/bin/env bash
#
# cleanup-fedora-plasma.sh
#
# Elimina aplicaciones que vienen por defecto en el spin de Fedora KDE Plasma
# y que normalmente no se usan. Script independiente del de instalación,
# para poder correrlo (o no) por separado.
#
# Uso:
#   chmod +x cleanup-fedora-plasma.sh
#   ./cleanup-fedora-plasma.sh
#
# El script solo quita paquetes que estén realmente instalados; si alguno no
# existe en tu instalación, se omite sin generar error.

set -uo pipefail

COLOR_RESET="\e[0m"
COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"
COLOR_BLUE="\e[34m"
COLOR_RED="\e[31m"

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_err()   { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"; }

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
        log_err "No se encontró 'sudo'. Instalalo antes de ejecutar este script."
        exit 1
    fi
    sudo -v
}

pkg_installed() {
    rpm -q "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# Lista de paquetes a eliminar, con nombre descriptivo para el log.
# Formato: "nombre_paquete|descripción"
# ---------------------------------------------------------------------------
PACKAGES_TO_REMOVE=(
    # --- Heredado del criterio usado en Debian (suite PIM / Kontact) ---
    "kmail|KMail (cliente de correo)"
    "kontact|Kontact (suite PIM)"
    "ktnef|KTnef (visor de adjuntos TNEF)"
    "kmouth|KMouth (texto a voz)"
    "konqueror|Konqueror (navegador/gestor de archivos)"
    "kaddressbook|KAddressBook (libreta de direcciones)"
    "kontrast|Kontrast (verificador de contraste)"
    "pim-data-exporter|Exportador de preferencias PIM"
    "kmousetool|KMouseTool"
    "ImageMagick|ImageMagick"
    "pim-sieve-editor|Editor de filtros Sieve"

    # --- Nuevas, específicas de este proyecto para Fedora ---
    "kmahjongg|KMahjongg (Mahjongg Solitario)"
    "kmines|KMines (Buscaminas)"
    "kpat|KPatience (juego de cartas solitario)"
    "skanpage|skanpage (escaneo de documentos)"
    "kamoso|kamoso (cámara web)"
    "krfb|krfb (Compartir escritorio - servidor)"
    "krdc|krdc (Cliente de escritorio remoto)"
    "neochat|NeoChat (cliente de Matrix)"
    "dragon|Dragon Player (reproductor multimedia)"
    "elisa-player|Elisa (reproductor de música)"

    # --- Añadidas en segunda ronda de limpieza ---
    "orca|Orca (lector de pantalla)"
    "kleopatra|Kleopatra (gestor de certificados GPG/S-MIME, arrastra Akonadi/MariaDB)"
    "akonadi-server|Akonadi (motor PIM, dependencia de Kleopatra)"
    "akonadi-mime|Akonadi Mime"
    "kcharselect|KCharSelect (selector de caracteres especiales)"
    "ibus|ibus (selector de método de entrada)"
    "ksystemlog|KSystemLog (visor de registro)"
    "kde-partitionmanager|Gestor de particiones KDE"
    "plasma-drkonqi|DrKonqi (informe de fallos de Plasma)"
    "akregator|Akregator (lector de RSS)"
    "kdeconnectd|KDE Connect (integración con el móvil)"
    "kolourpaint|KolourPaint (editor de imágenes básico)"
    "qrca|Qrca (escáner de códigos de barras/QR)"
    "gnome-abrt|GNOME ABRT (informe de problemas del sistema)"
)

# NOTA: al quitar kleopatra/akonadi-server, dnf arrastra como dependientes
# korganizer, incidenceeditor y el paquete completo kde-connect (no solo el
# daemon). Es intencional: libera ~450 MiB adicionales de la pila PIM/MariaDB.
# Si quieres conservar el calendario o KDE Connect, reinstálalos después con:
#   sudo dnf install kde-connect korganizer

main() {
    require_fedora
    require_root_privileges

    log_info "Revisando ${#PACKAGES_TO_REMOVE[@]} aplicaciones candidatas a eliminar..."

    local found=()
    local not_found=()

    for entry in "${PACKAGES_TO_REMOVE[@]}"; do
        local pkg="${entry%%|*}"
        local desc="${entry#*|}"
        if pkg_installed "$pkg"; then
            found+=("$pkg")
            echo "  [x] $desc ($pkg) — instalado, se eliminará"
        else
            not_found+=("$pkg")
        fi
    done

    if [[ ${#not_found[@]} -gt 0 ]]; then
        echo
        log_warn "No estaban instalados (se omiten): ${not_found[*]}"
    fi

    if [[ ${#found[@]} -eq 0 ]]; then
        echo
        log_ok "No hay nada que eliminar, el sistema ya está limpio de estos paquetes."
        exit 0
    fi

    echo
    if [[ ! -t 0 ]]; then
        log_err "La limpieza requiere una terminal interactiva para confirmar la eliminación."
        exit 1
    fi

    read -rp "¿Confirmás la eliminación de los ${#found[@]} paquetes listados arriba? [s/n]: " confirm
    case "${confirm,,}" in
        s|si|sí|y|yes) ;;
        *) log_info "Cancelado por el usuario. No se eliminó nada."; exit 0 ;;
    esac

    if sudo dnf remove -y "${found[@]}"; then
        log_ok "Limpieza completada."
        log_info "Si quieres revisar dependencias que ya no sean necesarias, puedes ejecutar manualmente: sudo dnf autoremove"
        log_info "Si quitaste componentes como KDE Connect o KOrganizer y luego los necesitas, puedes reinstalarlos con: sudo dnf install kde-connect korganizer"
    else
        log_err "La eliminación de paquetes no terminó correctamente."
        exit 1
    fi
}

main "$@"
