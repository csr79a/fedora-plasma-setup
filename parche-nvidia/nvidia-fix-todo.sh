#!/usr/bin/env bash
#
# nvidia-fix-todo.sh
#
# Script autónomo: no necesita ~/nvidia-fix, ni spec, ni parches previos.
# Compila el módulo NVIDIA Open desde las fuentes oficiales que trae el
# paquete xorg-x11-drv-nvidia-kmodsrc (RPM Fusion), le aplica la corrección
# para kernels 7.3 (necesaria para que funcione el RTD3 / suspensión de la
# dGPU) e instala los módulos para el kernel elegido.
#
# Uso:
#   ./nvidia-fix-todo.sh                          # kernel en ejecución
#   ./nvidia-fix-todo.sh 7.3.3-300.fc45.x86_64    # otro kernel instalado
#   FORCE=1 ./nvidia-fix-todo.sh                  # instalar aunque falle la
#                                                 # comprobación de la corrección
#
set -Eeuo pipefail

KERNEL="${1:-${KERNEL:-$(uname -r)}}"
FORCE="${FORCE:-0}"

WORK="$HOME/nvidia-fix"
BUILD="$WORK/build"
LOG="$WORK/compilacion-$KERNEL.log"
KSRC="/usr/src/kernels/$KERNEL"
DEST="/lib/modules/$KERNEL/extra/nvidia"

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
info() { echo; echo "[$1] $2"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
trap 'echo "ERROR en la línea $LINENO (comando: $BASH_COMMAND)" >&2' ERR

# Vuelca un módulo .ko/.ko.xz/.ko.zst/.ko.gz como .ko plano por stdout.
dump_module() {
    case "$1" in
        *.xz)  xz -dc "$1" ;;
        *.zst) zstd -dc "$1" ;;
        *.gz)  gzip -dc "$1" ;;
        *)     cat "$1" ;;
    esac
}

# 0 si el módulo importa el símbolo indicado. Se guarda la salida de nm en
# una variable para evitar falsos negativos por SIGPIPE con 'pipefail'.
module_has_symbol() {
    local mod="$1" sym="$2" tmp out
    tmp="$(mktemp)"
    dump_module "$mod" > "$tmp"
    out="$(nm -u "$tmp")"
    rm -f "$tmp"
    grep -qw -- "$sym" <<< "$out"
}

echo "========================================"
echo " NVIDIA (módulo Open) - Fedora"
echo " Kernel objetivo: $KERNEL"
echo "========================================"

# ---------------------------------------------------------------------------
info "1/8" "Comprobaciones previas..."
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] || die "ejecuta el script como usuario normal, no como root."
sudo -v
mkdir -p "$WORK"
if [[ ! -w "$WORK" ]]; then
    echo "$(ls -ld "$WORK")" >&2
    die "no puedo escribir en $WORK (¿pertenece a root?). Arréglalo con: sudo chown -R $USER: $WORK"
fi

# ---------------------------------------------------------------------------
info "2/8" "Instalando dependencias (fuentes del driver y herramientas)..."
# ---------------------------------------------------------------------------
sudo dnf install -y \
    xorg-x11-drv-nvidia-kmodsrc \
    "kernel-devel-$KERNEL" \
    gcc make binutils elfutils-libelf-devel \
    xz zstd gzip tar python3

[[ -d "$KSRC" ]] || die "no existe $KSRC (falta kernel-devel-$KERNEL)."

# ---------------------------------------------------------------------------
info "3/8" "Localizando las fuentes oficiales del driver..."
# ---------------------------------------------------------------------------
TARBALL=""
for f in /usr/share/nvidia-kmod-*/nvidia-kmod-*-x86_64.tar.xz; do
    [[ -f "$f" ]] && TARBALL="$f"
done
[[ -n "$TARBALL" ]] || die "no se encontró nvidia-kmod-*-x86_64.tar.xz en /usr/share."

VERSION="$(basename "$TARBALL")"
VERSION="${VERSION#nvidia-kmod-}"
VERSION="${VERSION%-x86_64.tar.xz}"
echo "Fuentes: $TARBALL"
echo "Versión del driver: $VERSION"

USERLAND="$(rpm -q --qf '%{VERSION}\n' xorg-x11-drv-nvidia 2>/dev/null || true)"
if [[ -n "$USERLAND" && "$USERLAND" != *"no está instalado"* \
      && "$USERLAND" != *"not installed"* && "$USERLAND" != "$VERSION" ]]; then
    echo "AVISO: xorg-x11-drv-nvidia es $USERLAND y el módulo será $VERSION."
fi

# Instantánea de los parámetros del módulo actual, para compararlos después.
PARAMS_ANTES="$WORK/params-antes-$(date +%Y%m%d-%H%M%S).txt"
if [[ -r /proc/driver/nvidia/params ]]; then
    if cat /proc/driver/nvidia/params > "$PARAMS_ANTES" 2>/dev/null; then
        echo "Guardados los parámetros actuales en $PARAMS_ANTES"
    else
        echo "AVISO: no se pudo guardar la instantánea de parámetros (se continúa)."
    fi
fi

# ---------------------------------------------------------------------------
info "4/8" "Extrayendo las fuentes..."
# ---------------------------------------------------------------------------
rm -rf "$BUILD"
mkdir -p "$BUILD"
tar -xf "$TARBALL" -C "$BUILD"

KDIR="$(find "$BUILD" -maxdepth 3 -type d -name kernel-open -print -quit)"
[[ -n "$KDIR" ]] || die "las fuentes no contienen 'kernel-open'; este script solo soporta el módulo Open."

# ---------------------------------------------------------------------------
info "5/8" "Aplicando la corrección para kernel 7.3..."
# ---------------------------------------------------------------------------
set +e
python3 - "$KDIR" <<'PY'
import re
import sys
import pathlib

kdir = pathlib.Path(sys.argv[1])
status = 0


def edit(rel, func, label):
    """Aplica func al archivo; None = no aplicable, igual = ya aplicado."""
    global status
    path = kdir / rel
    old = path.read_text()
    new = func(old)
    if new is None:
        print(f"AVISO: no se pudo aplicar '{label}' en {rel} (¿versión distinta del driver?)")
        status = 2
    elif new == old:
        print(f"  = {label}: ya estaba aplicado")
    else:
        path.write_text(new)
        print(f"  OK {label}")


def macro_defined_somewhere(name):
    exts = {".c", ".h", ".sh", ".Kbuild", ".mk"}
    for f in kdir.rglob("*"):
        if f.is_file() and (f.suffix in exts or f.name in ("Makefile", "Kbuild")):
            try:
                if f.stat().st_size < 4_000_000 and name in f.read_text(errors="ignore"):
                    return True
            except OSError:
                pass
    return False


def kbuild(s):
    if "is_export_symbol_present_userspace_init_fs" in s:
        return s
    found = list(re.finditer(r'^NV_CONFTEST_SYMBOL_COMPILE_TESTS \+= [^\n]*\n', s, re.M))
    if not found:
        return None
    pos = found[-1].end()
    extra = ("NV_CONFTEST_SYMBOL_COMPILE_TESTS += is_export_symbol_present_userspace_init_fs\n"
             "NV_CONFTEST_SYMBOL_COMPILE_TESTS += is_export_symbol_gpl_userspace_init_fs\n")
    return s[:pos] + extra + s[pos:]


async_defined = macro_defined_somewhere("NV_PCI_ASYNC_PROBE_SUPPORTED")


def pci(s):
    t = s
    if "scoped_with_init_fs" not in t:
        inc = "#include <linux/kthread.h>\n"
        if inc not in t:
            return None
        t = t.replace(
            inc,
            inc + "#if NV_CHECK_EXPORT_SYMBOL(userspace_init_fs)\n"
                  "#include <linux/fs_struct.h>\n#endif\n",
            1,
        )
        pat = re.compile(
            r'^([ \t]*)struct file \*file = filp_open\(filename, O_RDONLY, 0\);\n', re.M)
        m = pat.search(t)
        if not m:
            return None
        i = m.group(1)
        block = (
            f"{i}struct file *file;\n"
            "\n"
            "#if NV_CHECK_EXPORT_SYMBOL(userspace_init_fs)\n"
            f"{i}/*\n"
            f"{i} * Linux 7.3: resolve sysfs paths using init's filesystem\n"
            f"{i} * context when running from a kernel thread.\n"
            f"{i} */\n"
            f"{i}scoped_with_init_fs()\n"
            f"{i}    file = filp_open(filename, O_RDONLY, 0);\n"
            "#else\n"
            f"{i}file = filp_open(filename, O_RDONLY, 0);\n"
            "#endif\n"
        )
        t = t[:m.start()] + block + t[m.end():]

    old = "if (!smp_load_acquire(&nv_pci_driver_registration_in_progress))"
    if async_defined and old in t and "!NV_PCI_ASYNC_PROBE_SUPPORTED" not in t:
        t = t.replace(
            old,
            "if (!NV_PCI_ASYNC_PROBE_SUPPORTED ||\n"
            "        !smp_load_acquire(&nv_pci_driver_registration_in_progress))",
            1,
        )
    return t


edit("nvidia/nvidia.Kbuild", kbuild, "tests de conftest para userspace_init_fs")
edit("nvidia/nv-pci.c", pci, "apertura de sysfs con el contexto de init y probe")
sys.exit(status)
PY
FIX_RC=$?
set -e
if [[ $FIX_RC -ne 0 ]]; then
    echo "AVISO: alguna parte de la corrección no se pudo aplicar."
    echo "       Puede que este driver ya la traiga corregida de otra forma."
fi

# ---------------------------------------------------------------------------
info "6/8" "Compilando (puede tardar unos minutos)..."
# ---------------------------------------------------------------------------
VARS=(KERNEL_UNAME="$KERNEL" KERNEL_SOURCES="$KSRC" KERNEL_OUTPUT="$KSRC"
      SYSSRC="$KSRC" SYSOUT="$KSRC" IGNORE_CC_MISMATCH=1)

: > "$LOG"
echo "== Intento 1: Makefile de kernel-open ==" >> "$LOG"
make -j"$(nproc)" -C "$KDIR" modules "${VARS[@]}" >> "$LOG" 2>&1 || true

if [[ ! -f "$KDIR/nvidia.ko" ]]; then
    echo "== Intento 2: Kbuild directo (M=) ==" >> "$LOG"
    make -j"$(nproc)" -C "$KSRC" M="$KDIR" IGNORE_CC_MISMATCH=1 modules >> "$LOG" 2>&1 || true
fi

if [[ ! -f "$KDIR/nvidia.ko" ]]; then
    tail -40 "$LOG" >&2
    die "no se generó nvidia.ko. Registro completo en $LOG"
fi

BUILT_VER="$(modinfo -F version "$KDIR/nvidia.ko")"
echo "Módulo compilado, versión: $BUILT_VER"
[[ "$BUILT_VER" == "$VERSION" ]] || die "la versión del módulo ($BUILT_VER) no coincide con la de las fuentes ($VERSION)."

# ---------------------------------------------------------------------------
info "7/8" "Verificando que la corrección quedó dentro del módulo..."
# ---------------------------------------------------------------------------
if grep -qw "userspace_init_fs" "$KSRC/Module.symvers"; then
    if module_has_symbol "$KDIR/nvidia.ko" userspace_init_fs; then
        echo "OK: el módulo usa userspace_init_fs (corrección activa)."
    elif [[ "$FORCE" == "1" ]]; then
        echo "AVISO: el módulo no usa userspace_init_fs; se instala por FORCE=1."
    else
        die "el módulo NO incluye la corrección; sin ella el RTD3 saldría 'Not supported'. No se instala nada (usa FORCE=1 para instalarlo igualmente)."
    fi
else
    echo "Este kernel no exporta userspace_init_fs: no hace falta la corrección."
fi

# ---------------------------------------------------------------------------
info "8/8" "Instalando módulos..."
# ---------------------------------------------------------------------------
mapfile -t KOS < <(find "$KDIR" -maxdepth 2 -type f -name '*.ko')
[[ ${#KOS[@]} -ge 1 ]] || die "no hay módulos .ko que instalar."

# Copia de seguridad de los módulos actuales (fuera de /lib/modules para que
# depmod no la tome en cuenta).
if [[ -d "$DEST" ]]; then
    BACKUP="$WORK/copia-modulos-$KERNEL-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP"
    sudo cp -a "$DEST/." "$BACKUP/"
    sudo chown -R "$USER": "$BACKUP"
    echo "Copia de los módulos anteriores: $BACKUP"
fi

# Misma compresión que usan el resto de módulos de este kernel.
EXT=""
REF="$(find "/lib/modules/$KERNEL/kernel/fs" -maxdepth 2 -name 'ext4.ko*' -print -quit 2>/dev/null || true)"
case "$REF" in
    *.xz)  EXT=".xz" ;;
    *.zst) EXT=".zst" ;;
    *.gz)  EXT=".gz" ;;
esac

sudo install -d -m 0755 "$DEST"
for ko in "${KOS[@]}"; do
    name="$(basename "$ko")"
    sudo rm -f "$DEST/$name" "$DEST/$name.xz" "$DEST/$name.zst" "$DEST/$name.gz"
    case "$EXT" in
        .xz)  xz --check=crc32 --lzma2=dict=512KiB -c "$ko" | sudo tee "$DEST/$name.xz"  >/dev/null ;;
        .zst) zstd -q -19 -c "$ko"                          | sudo tee "$DEST/$name.zst" >/dev/null ;;
        .gz)  gzip -9 -c "$ko"                              | sudo tee "$DEST/$name.gz"  >/dev/null ;;
        *)    sudo install -m 0644 "$ko" "$DEST/$name" ;;
    esac
    echo "  instalado: $name$EXT"
done
sudo chmod 0644 "$DEST"/*
sudo restorecon -R "$DEST" 2>/dev/null || true

sudo depmod -a "$KERNEL"
sudo dracut -f --kver "$KERNEL"

# Verificación final del módulo ya instalado.
INST_MOD="$(modinfo -k "$KERNEL" -n nvidia)"
echo "Módulo instalado: $INST_MOD"
echo "Versión: $(modinfo -k "$KERNEL" -F version nvidia)"
if grep -qw "userspace_init_fs" "$KSRC/Module.symvers"; then
    module_has_symbol "$INST_MOD" userspace_init_fs \
        || echo "AVISO: el módulo instalado no usa userspace_init_fs."
fi

echo
echo "========================================"
echo " PROCESO TERMINADO"
echo "========================================"
echo
echo "Kernel objetivo: $KERNEL"
if [[ "$(uname -r)" != "$KERNEL" ]]; then
    echo "AVISO: ahora mismo estás en $(uname -r), no en $KERNEL."
fi
echo "No se ha reiniciado. Hasta reiniciar sigue cargado el módulo anterior."
echo
echo "Después de reiniciar:"
echo "  cat /proc/driver/nvidia/gpus/*/power | head -2    # Enabled (fine-grained)"
echo "  diff $PARAMS_ANTES /proc/driver/nvidia/params"
echo "  sleep 30; cardwire gpu 1 --power                  # D3cold"