# fedora-plasma-setup

Colección de scripts para preparar **Fedora Workstation / KDE Plasma**, manteniendo separadas la configuración general del sistema y la configuración específica para gaming.

## Estructura

```
fedora-plasma-setup/
├── gui/
│   └── fedora_setup_gui.py
├── plasma/
│   ├── setup-fedora-plasma.sh
│   └── cleanup-fedora-plasma.sh
├── nvidia/
│   └── setup-nvidia.sh
├── asus/
│   └── setup-asusctl.sh
├── gaming/
│   └── setup-gaming-fedora.sh
├── README.md
└── MANUAL.md
```

## GUI

La interfaz gráfica está desarrollada en **Python 3 + PyQt6** y actúa como una interfaz de control sobre los scripts Bash existentes. La GUI no duplica la lógica de instalación.

### Requisitos previos para la GUI

Antes de abrir la GUI hay que tener instalados:

- Python 3
- PyQt6
- `sudo`

En Fedora:

```bash
sudo dnf install python3 python3-pyqt6 sudo
```

Comprobar que Python y PyQt6 están disponibles:

```bash
python3 --version
python3 -c "import PyQt6; print('PyQt6 OK')"
```

Desde la raíz del repositorio, iniciar la GUI con:

```bash
python3 gui/fedora_setup_gui.py
```

La GUI utiliza un pseudo-terminal para permitir que los scripts interactúen con `sudo` y con sus preguntas `[s/n]`. Por eso, la contraseña de `sudo` y las respuestas solicitadas por los scripts se pueden introducir desde la propia ventana.

La GUI es opcional. Todos los componentes siguen pudiendo ejecutarse directamente desde la terminal.

## Fedora: instalación nueva, actualización y conflicto de KMime

> **Esta sección es exclusiva para Fedora. No se aplica a Debian.**

En una instalación nueva de Fedora, **actualiza primero el sistema y reinicia antes de continuar con la instalación de paquetes o componentes del proyecto**.

Ejecuta:

```bash
sudo dnf upgrade --refresh
sudo reboot
```

Después del reinicio, vuelve a ejecutar la instalación del paquete o componente que estabas instalando.

### Conflicto entre `kf6-kmime` y `kmime`

Si durante una instalación aparece un error de RPM indicando que archivos como `libkmime6_qt.qm` o `kmime.categories` entran en conflicto entre `kf6-kmime` y `kmime`, **no borres archivos manualmente**.

Primero sincroniza los paquetes con los repositorios actuales:

```bash
sudo dnf distro-sync --refresh
```

Si Fedora solicita reiniciar, hazlo:

```bash
sudo reboot
```

Después del reinicio, vuelve a intentar instalar el paquete que produjo el conflicto.

Si el conflicto continúa, comprueba qué versiones están instaladas y qué paquetes dependen de ellas:

```bash
rpm -q kmime kf6-kmime
dnf repoquery --whatrequires kmime
dnf repoquery --whatrequires kf6-kmime
```

Con esa información se puede determinar qué paquete debe mantenerse antes de realizar cualquier eliminación.

**No se recomienda** borrar archivos de `/usr/share` manualmente ni forzar la transacción con opciones como `--replacefiles` sin haber identificado previamente la causa del conflicto.

## Plasma

`plasma/setup-fedora-plasma.sh` realiza la configuración general de Fedora KDE Plasma: DNF, actualización del sistema, RPM Fusion, multimedia, microcódigo, códecs AMD, swappiness y Flatpak/Flathub.

`nvidia/setup-nvidia.sh` es el componente independiente para detectar la GPU NVIDIA, instalar `akmod-nvidia`, `libva-nvidia-driver` y las herramientas de diagnóstico `switcherooctl`/`glxinfo`. También crea `nvidia-run` para PRIME Render Offload y verifica el renderizado OpenGL con y sin offload.

`asus/setup-asusctl.sh` es el componente independiente para hardware ASUS: `asusctl`, `asusd`, `power-profiles-daemon` y, opcionalmente, ROG Control Center.

`plasma/cleanup-fedora-plasma.sh` es independiente y elimina, previa confirmación, aplicaciones de KDE que no se quieran conservar.

## Gaming

`gaming/setup-gaming-fedora.sh` es un componente independiente para gaming. Instala/configura Steam, ProtonPlus, Heroic Games Launcher, GameMode, MangoHud, GOverlay, `vm.max_map_count`, `ntsync` y `game-performance`.

No es necesario ejecutar el script de gaming si solo se quiere preparar Fedora Plasma.

## Orden recomendado

Para una instalación nueva:

1. Actualizar Fedora y reiniciar siguiendo la sección **“Fedora: instalación nueva, actualización y conflicto de KMime”**.
2. Ejecutar `plasma/setup-fedora-plasma.sh`.
3. Si el equipo tiene NVIDIA, ejecutar `nvidia/setup-nvidia.sh`.
4. Si el equipo es ASUS, ejecutar `asus/setup-asusctl.sh`.
5. Reiniciar si corresponde, especialmente después de instalar NVIDIA.
6. Ejecutar `gaming/setup-gaming-fedora.sh` si se quiere preparar el equipo para jugar.
7. Ejecutar `plasma/cleanup-fedora-plasma.sh` solo si se desea realizar la limpieza opcional.

Los scripts siguen siendo independientes y pueden ejecutarse por separado.

## Documentación

La documentación detallada de ambos componentes está reunida en [MANUAL.md](MANUAL.md).

## Migración

El componente que estaba en `setup-gaming-fedora` se ha integrado aquí bajo `gaming/`, manteniendo su script separado del setup de Plasma.
