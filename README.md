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
sudo dnf install python3 python3-qt6 sudo
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

## Plasma

`plasma/setup-fedora-plasma.sh` realiza la configuración general de Fedora KDE Plasma: DNF, actualización del sistema, RPM Fusion, multimedia, microcódigo, códecs AMD, swappiness y Flatpak/Flathub.

`nvidia/setup-nvidia.sh` es el componente independiente para detectar la GPU NVIDIA, instalar `libva-nvidia-driver` y, opcionalmente, `akmod-nvidia` + CUDA.

`asus/setup-asusctl.sh` es el componente independiente para hardware ASUS: `asusctl`, `asusd`, `power-profiles-daemon` y, opcionalmente, ROG Control Center.

`plasma/cleanup-fedora-plasma.sh` es independiente y elimina, previa confirmación, aplicaciones de KDE que no se quieran conservar.

## Gaming

`gaming/setup-gaming-fedora.sh` es un componente independiente para gaming. Instala/configura Steam, ProtonPlus, Heroic Games Launcher, GameMode, MangoHud, GOverlay, `vm.max_map_count`, `ntsync` y los alias de rendimiento.

No es necesario ejecutar el script de gaming si solo se quiere preparar Fedora Plasma.

## Orden recomendado

Para una instalación nueva:

1. Ejecutar `plasma/setup-fedora-plasma.sh`.
2. Si el equipo tiene NVIDIA, ejecutar `nvidia/setup-nvidia.sh`.
3. Si el equipo es ASUS, ejecutar `asus/setup-asusctl.sh`.
4. Reiniciar si corresponde, especialmente después de instalar NVIDIA.
5. Ejecutar `gaming/setup-gaming-fedora.sh` si se quiere preparar el equipo para jugar.
6. Ejecutar `plasma/cleanup-fedora-plasma.sh` solo si se desea realizar la limpieza opcional.

Los scripts siguen siendo independientes y pueden ejecutarse por separado.

## Documentación

La documentación detallada de ambos componentes está reunida en [MANUAL.md](MANUAL.md).

## Migración

El componente que estaba en `setup-gaming-fedora` se ha integrado aquí bajo `gaming/`, manteniendo su script separado del setup de Plasma.
