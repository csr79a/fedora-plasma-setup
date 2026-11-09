#!/usr/bin/env bash
#
# setup-asusctl.sh  (versión Fedora KDE Plasma)
#
# Configuración de asusctl / asusd / ROG Control Center y Cardwire (gestor de
# GPU híbrida) para hardware ASUS. Los paquetes vienen de Terra (repo de
# terceros de Fyra Labs).
# Este componente es independiente de setup-fedora-plasma.sh.
#
# Uso interactivo:
#   chmod +x setup-asusctl.sh
#   ./setup-asusctl.sh
#
# Uso sin terminal (lanzador gráfico, SSH sin TTY, automatización):
#   ASUSCTL=1 CARDWIRE=1 ./setup-asusctl.sh
#
# Variables de entorno (1/0, s/n, yes/no):
#   ASUSCTL          instalar asusctl.               Sin TTY es obligatoria.
#   CARDWIRE         instalar Cardwire.              Sin TTY es obligatoria.
#   ROG_GUI          instalar ROG Control Center.    Sin TTY: 0 por defecto.
#   CARDWIRE_ADD_BPF añadir 'bpf' a los LSM del
#                    kernel con grubby si falta.     Sin TTY: 0 por defecto.
#   TERRA_RESTRICT   0 = no restringir Terra con includepkgs (por defecto 1).
#
# Con terminal, 'dnf install --allowerasing cardwire' se ejecuta SIN -y a
# propósito: dnf muestra los paquetes que va a eliminar y pide confirmación.
# Sin terminal se usa -y (no hay nadie para confirmar).
#
# Requiere un usuario normal con sudo. No ejecutar como root.
#
# Avisos y fallos:
#   aviso  algo opcional o informativo no se pudo hacer (no cambia el resultado).
#   fallo  algo que el script debía dejar instalado o configurado no quedó así.
#
# Códigos de salida:
#   0  correcto (con o sin avisos), o sin hardware ASUS, o el usuario omitió todo
#   1  hubo al menos un fallo (se listan en el resumen final), el sistema no es
#      Fedora con KDE Plasma, o faltan variables de entorno sin terminal

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

# Estado compartido entre pasos.
WANT_ASUSCTL=0
WANT_CARDWIRE=0
REBOOT_NEEDED=false
TERRA_RESTRICTED=false
STEP_N=0
STEP_TOTAL=0

TERRA_REPO_FILE="/etc/yum.repos.d/terra.repo"
# Paquetes de Terra que se permiten tras restringir el repo.
TERRA_INCLUDE_PKGS="terra-release* asusctl* rog-control-center* cardwire*"

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; WARNINGS+=("$*"); }
log_err()   { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"; }
log_step()  { echo -e "\n${COLOR_BLUE}==>${COLOR_RESET} \e[1m$*${COLOR_RESET}"; }

# Fallo real: se muestra y se acumula; el script termina con código 1.
record_fail() { log_err "$*"; FAILURES+=("$*"); }

# Paso numerado con el total real (depende de lo que el usuario haya elegido).
next_step() {
    STEP_N=$((STEP_N + 1))
    log_step "${STEP_N}/${STEP_TOTAL} · $*"
}

# ---------------------------------------------------------------------------
# Entrada del usuario: variable de entorno → pregunta interactiva → error
# ---------------------------------------------------------------------------
ask_yes_no() {
    local prompt="$1"
    local answer
    while true; do
        read -rp "$(echo -e "${COLOR_YELLOW}?${COLOR_RESET} ${prompt} [s/n]: ")" answer || return 1
        case "${answer,,}" in
            s|si|sí|y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "  Responde 's' o 'n'." ;;
        esac
    done
}

# Uso: choice <VARIABLE> <pregunta> [defecto_sin_terminal: 0|1]
# Devuelve 0 (sí) o 1 (no).
#  1. Si la variable de entorno está definida, se usa su valor.
#  2. Si hay terminal, se pregunta.
#  3. Sin terminal: se usa el defecto si se indicó; si no, error (exit 1).
choice() {
    local var="$1" prompt="$2" default="${3:-}"
    local val="${!var:-}"

    case "${val,,}" in
        1|s|si|sí|y|yes|true)  return 0 ;;
        0|n|no|false)          return 1 ;;
        "") ;;
        *)
            log_err "Valor no válido en ${var}='${val}' (usa 1 o 0)."
            exit 1
            ;;
    esac

    if [[ -t 0 ]]; then
        ask_yes_no "$prompt"
        return $?
    fi

    case "$default" in
        1) log_info "Sin terminal y ${var} sin definir: se usa 1 por defecto."; return 0 ;;
        0) log_info "Sin terminal y ${var} sin definir: se usa 0 por defecto."; return 1 ;;
    esac

    log_err "Sin terminal interactiva y ${var} no está definida. Ejecuta con ${var}=1 o ${var}=0."
    exit 1
}

# ---------------------------------------------------------------------------
# Comprobaciones previas
# ---------------------------------------------------------------------------
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
        log_err "No corras este script directamente como root. Ejecútalo como tu usuario normal."
        exit 1
    fi
    if ! command -v sudo &>/dev/null; then
        log_err "No se encontró 'sudo'."
        exit 1
    fi
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

service_state() {
    systemctl is-active "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Terra
# ---------------------------------------------------------------------------
# Habilita Terra (repo de terceros de Fyra Labs) si no lo está.
ensure_terra() {
    if pkg_installed terra-release || \
       dnf repolist --enabled 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx 'terra'; then
        log_ok "Terra ya está habilitado"
        return 0
    fi

    log_warn "Terra es un repositorio de terceros (Fyra Labs)."
    log_info "Para quitarlo después: sudo dnf remove terra-release"

    # --nogpgcheck solo afecta a este bootstrap de terra-release (método oficial);
    # 'terra-release' instala después la clave GPG del repo.
    sudo dnf install -y --nogpgcheck \
        --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
        terra-release

    if pkg_installed terra-release; then
        log_ok "Terra habilitado"
        return 0
    fi
    record_fail "No se pudo habilitar Terra. Instrucciones oficiales: https://developer.fyralabs.com/terra/installing"
    return 1
}

# Terra es un repo grande: sin restricción, 'dnf upgrade' podría sustituir
# paquetes de Fedora o RPM Fusion por versiones de Terra. Se limita a los
# paquetes de este script. Se aplica DESPUÉS de instalar, y solo si no hubo
# fallos, para no cortar dependencias que aún falten.
restrict_terra() {
    if [[ "${TERRA_RESTRICT:-1}" == "0" ]]; then
        log_info "TERRA_RESTRICT=0: Terra se deja sin restringir."
        return 0
    fi
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        log_warn "Hubo fallos en la instalación; no se restringe Terra para no cortar dependencias."
        return 0
    fi
    if [[ ! -f "$TERRA_REPO_FILE" ]]; then
        log_warn "No se encontró ${TERRA_REPO_FILE}; no se pudo restringir Terra."
        return 0
    fi
    if grep -qE '^[[:space:]]*includepkgs=' "$TERRA_REPO_FILE"; then
        TERRA_RESTRICTED=true
        log_ok "Terra ya estaba restringido con includepkgs"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    # Inserta includepkgs justo debajo de la cabecera [terra].
    if awk -v inc="includepkgs=${TERRA_INCLUDE_PKGS}" \
        '{print} $0=="[terra]" {print inc}' "$TERRA_REPO_FILE" >"$tmp" \
        && sudo install -m 0644 "$tmp" "$TERRA_REPO_FILE" \
        && grep -qE '^[[:space:]]*includepkgs=' "$TERRA_REPO_FILE"; then
        TERRA_RESTRICTED=true
        log_ok "Terra restringido a: ${TERRA_INCLUDE_PKGS}"
        log_info "Si luego quieres otro paquete de Terra, añade su nombre a includepkgs en ${TERRA_REPO_FILE}."
    else
        log_warn "No se pudo restringir Terra (se deja sin restringir)."
    fi
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# asusctl
# ---------------------------------------------------------------------------
install_asusctl() {
    install_verified asusctl || return 1

    # asusd necesita la API D-Bus de power-profiles-daemon. En Fedora 41+ el
    # valor por defecto es tuned-ppd; la guía de asus-linux indica sustituirlo
    # por power-profiles-daemon (con tuned-ppd el cambio de perfiles puede
    # comportarse de forma impredecible).
    if pkg_installed tuned-ppd; then
        log_warn "Se sustituirá tuned-ppd por power-profiles-daemon. dnf también eliminará tuned y las dependencias que solo usaba él (kernel-tools, hdparm, virt-what...)."
        sudo dnf swap -y tuned-ppd power-profiles-daemon --allowerasing
        if pkg_installed power-profiles-daemon && ! pkg_installed tuned-ppd; then
            log_ok "tuned-ppd reemplazado por power-profiles-daemon"
        else
            record_fail "No se pudo sustituir tuned-ppd por power-profiles-daemon."
            return 1
        fi
    fi

    install_verified power-profiles-daemon || return 1

    if ! sudo systemctl enable --now power-profiles-daemon.service; then
        record_fail "No se pudo habilitar power-profiles-daemon.service."
        return 1
    fi
    log_ok "power-profiles-daemon activo"

    # asusd se arranca por udev/D-Bus; si 'enable' no aplica a la unidad (no
    # tiene sección [Install]), basta con que esté activa.
    if sudo systemctl enable --now asusd.service || systemctl is-active --quiet asusd.service; then
        log_ok "asusd.service activo"
    else
        record_fail "asusd.service no está activo. Si es la primera instalación, reinicia y revisa: journalctl -u asusd -b --no-pager | tail -n 40"
        return 1
    fi

    if choice ROG_GUI "¿Instalar también ROG Control Center (GUI para asusctl)?" 0; then
        install_optional asusctl-rog-gui || true
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Cardwire
# ---------------------------------------------------------------------------
# El demonio de Cardwire se niega a arrancar si 'bpf' no está entre los LSM activos.
bpf_lsm_active() {
    local lsm
    lsm="$(cat /sys/kernel/security/lsm 2>/dev/null || true)"
    [[ ",$lsm," == *,bpf,* ]]
}

# Añade 'bpf' a la lista de LSM actual como parámetro de kernel. Hace falta reiniciar.
add_bpf_lsm_arg() {
    local lsm
    lsm="$(cat /sys/kernel/security/lsm 2>/dev/null || true)"

    if [[ -z "$lsm" ]]; then
        log_warn "No se pudo leer /sys/kernel/security/lsm; no se puede construir el parámetro lsm=."
        return 1
    fi
    if ! command -v grubby &>/dev/null; then
        log_warn "grubby no está instalado; añade manualmente lsm=${lsm},bpf a la línea de comandos del kernel."
        return 1
    fi
    if sudo grubby --update-kernel=ALL --args="lsm=${lsm},bpf"; then
        REBOOT_NEEDED=true
        log_ok "Añadido lsm=${lsm},bpf a los kernels instalados; hace falta reiniciar"
        return 0
    fi
    log_warn "grubby no pudo añadir el parámetro lsm=."
    return 1
}

enable_cardwired() {
    if ! systemctl cat cardwired.service &>/dev/null; then
        record_fail "No se encontró cardwired.service tras instalar cardwire."
        return 1
    fi

    if bpf_lsm_active; then
        log_ok "BPF LSM activo (requisito de Cardwire)"
        if sudo systemctl enable --now cardwired.service; then
            log_ok "cardwired habilitado e iniciado"
            return 0
        fi
        record_fail "No se pudo habilitar/iniciar cardwired. Revisa: journalctl -u cardwired -b --no-pager | tail -n 40"
        return 1
    fi

    # Sin 'bpf', cardwired no puede arrancar: se ofrece activarlo y, en cualquier
    # caso, se deja el servicio habilitado (sin arrancar) para el próximo inicio.
    log_warn "'bpf' no figura en /sys/kernel/security/lsm: cardwired no arrancará hasta activarlo."
    if choice CARDWIRE_ADD_BPF "¿Añadir 'bpf' a los LSM del kernel con grubby? (requiere reiniciar)" 0; then
        add_bpf_lsm_arg || true
    else
        log_info "Se omite el cambio de kernel. Comprueba: cat /sys/kernel/security/lsm   y   grep CONFIG_BPF_LSM /boot/config-\$(uname -r)"
    fi

    if sudo systemctl enable cardwired.service; then
        log_info "cardwired queda habilitado; arrancará tras reiniciar con 'bpf' activo."
        return 0
    fi
    record_fail "No se pudo habilitar cardwired.service."
    return 1
}

# La GUI es un paquete aparte (cardwire-gui). Es opcional: la CLI y el demonio
# funcionan sin ella, así que un fallo solo avisa.
install_cardwire_gui() {
    install_optional cardwire-gui || true
}

install_cardwire() {
    if [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
        log_warn "Cardwire solo soporta Wayland y esta sesión es X11."
    fi

    if pkg_installed cardwire; then
        log_ok "cardwire ya está instalado"
    else
        # --allowerasing: cardwire declara conflicto con switcheroo-control, que
        # Fedora trae instalado.
        local dnf_args=(--allowerasing)
        if pkg_installed switcheroo-control; then
            log_warn "cardwire entra en conflicto con switcheroo-control y dnf lo eliminará."
            log_info "En Plasma puede desaparecer la opción de ejecutar con la GPU dedicada del menú de aplicaciones; usa 'cardwire launch <programa>'."
        fi
        if [[ -t 0 ]]; then
            log_info "dnf mostrará la lista completa de paquetes a eliminar y pedirá confirmación. Revísala antes de aceptar."
        else
            log_info "Sin terminal: se instala con -y (no hay forma de pedir confirmación)."
            dnf_args+=(-y)
        fi

        sudo dnf install "${dnf_args[@]}" cardwire
        if pkg_installed cardwire; then
            log_ok "cardwire instalado"
        else
            record_fail "cardwire no quedó instalado (error de dnf o cancelado)."
            return 1
        fi
    fi

    install_cardwire_gui
    enable_cardwired
}

# ---------------------------------------------------------------------------
# Resumen final (comprueba el estado real, no solo códigos de salida)
# ---------------------------------------------------------------------------
step_summary() {
    next_step "Resumen"
    echo "Estado de componentes principales:"

    local state
    echo "  - Terra: $(pkg_installed terra-release && echo habilitado || echo 'NO habilitado')$($TERRA_RESTRICTED && echo ' (restringido)')"

    if [[ "$WANT_ASUSCTL" -eq 1 ]]; then
        pkg_installed asusctl && echo "  - asusctl: instalado" || echo "  - asusctl: NO instalado"
        state="$(service_state asusd.service)"
        echo "  - asusd.service: ${state}"
        state="$(service_state power-profiles-daemon.service)"
        echo "  - power-profiles-daemon.service: ${state}"
        pkg_installed asusctl-rog-gui && echo "  - ROG Control Center: instalado"
    fi

    if [[ "$WANT_CARDWIRE" -eq 1 ]]; then
        pkg_installed cardwire && echo "  - cardwire: instalado" || echo "  - cardwire: NO instalado"
        pkg_installed cardwire-gui && echo "  - cardwire-gui: instalado"
        state="$(service_state cardwired.service)"
        echo "  - cardwired.service: ${state}"
        if bpf_lsm_active; then
            echo "  - BPF LSM: activo"
        else
            echo "  - BPF LSM: NO activo (cardwired no arrancará hasta activarlo)"
        fi
    fi

    if $REBOOT_NEEDED; then
        echo
        log_info "Reinicia el equipo para aplicar los cambios de kernel."
    fi

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

    log_step "Detectando hardware ASUS"

    local vendor
    vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")"

    if [[ "$vendor" != *ASUS* ]]; then
        log_info "No se detectó hardware ASUS (fabricante detectado: '${vendor:-desconocido}')."
        return 0
    fi

    log_info "Hardware ASUS detectado ($vendor)"

    if choice ASUSCTL "¿Instalar herramientas ASUS Linux (asusctl)?"; then
        WANT_ASUSCTL=1
    else
        log_info "Se omite asusctl a pedido del usuario"
    fi

    if choice CARDWIRE "¿Instalar Cardwire (gestor de GPU híbrida)?"; then
        WANT_CARDWIRE=1
    else
        log_info "Se omite Cardwire a pedido del usuario"
    fi

    if [[ "$WANT_ASUSCTL" -eq 0 && "$WANT_CARDWIRE" -eq 0 ]]; then
        return 0
    fi

    # Pasos: Terra + (asusctl) + (cardwire) + (restringir Terra) + resumen
    STEP_TOTAL=$((1 + WANT_ASUSCTL + WANT_CARDWIRE + 1))
    [[ "${TERRA_RESTRICT:-1}" != "0" ]] && STEP_TOTAL=$((STEP_TOTAL + 1))

    next_step "Habilitando repositorio Terra"
    if ! ensure_terra; then
        step_summary || true
        return 1
    fi

    if [[ "$WANT_ASUSCTL" -eq 1 ]]; then
        next_step "Instalando asusctl y configurando servicios"
        install_asusctl || true
    fi

    if [[ "$WANT_CARDWIRE" -eq 1 ]]; then
        next_step "Instalando Cardwire"
        install_cardwire || true
    fi

    if [[ "${TERRA_RESTRICT:-1}" != "0" ]]; then
        next_step "Restringiendo Terra a los paquetes de este script"
        restrict_terra
    fi

    step_summary
    return $?
}

# Solo ejecuta main si el archivo se lanza directamente (no si se hace 'source').
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi