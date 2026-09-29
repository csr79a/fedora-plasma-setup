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

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }

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
    "dragonplayer|Dragon Player (reproductor multimedia)"
    "elisa|Elisa (reproductor de música)"

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
    read -rp "¿Confirmás la eliminación de los ${#found[@]} paquetes listados arriba? [s/n]: " confirm
    case "${confirm,,}" in
        s|si|sí|y|yes) ;;
        *) log_info "Cancelado por el usuario. No se eliminó nada."; exit 0 ;;
    esac

    sudo dnf remove -y "${found[@]}"
    log_ok "Limpieza completada."
}

main "$@"
