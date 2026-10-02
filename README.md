# fedora-plasma-setup

Colección de scripts para preparar **Fedora Workstation / KDE Plasma**, manteniendo separadas la configuración general del sistema, NVIDIA, ASUS/ROG y gaming.

El repositorio incluye una **GUI en PyQt6** que sirve como lanzador de los scripts Bash reales. La GUI no duplica la lógica de instalación: ejecuta los mismos scripts que pueden ejecutarse desde la terminal.

## Estructura

```text
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

---

## Requisitos

### Sistema

- Fedora Workstation / KDE Plasma.
- Usuario normal con permisos de `sudo`.
- Conexión a internet.
- No ejecutar los scripts directamente como `root`.
- Los scripts de Plasma verifican que el sistema sea Fedora antes de realizar cambios.

Para obtener el repositorio y disponer de las herramientas básicas:

```bash
sudo dnf install -y git curl sudo
```

### GUI

La interfaz gráfica necesita:

- Python 3
- PyQt6
- sudo
- Un entorno gráfico funcional

Instalar las dependencias de la GUI:

```bash
sudo dnf install -y python3 python3-pyqt6 sudo
```

Comprobarlas:

```bash
python3 --version
python3 -c "import PyQt6; print('PyQt6 OK')"
sudo -V
```

No se necesita `pyte` ni ninguna dependencia Python adicional para la GUI.

---

# GUI — Fedora Plasma Setup

La GUI se encuentra en:

```text
gui/fedora_setup_gui.py
```

Está construida con **Python 3 + PyQt6** y utiliza un **pseudo-terminal (PTY)** real para ejecutar los scripts Bash.

Esto permite que:

- `sudo` funcione de forma interactiva.
- Las preguntas de los scripts puedan responderse desde la ventana.
- La contraseña de `sudo` se introduzca en el campo de entrada sin mostrarse.
- La salida con colores ANSI se conserve en el panel de ejecución.
- Un proceso pueda cancelarse desde la propia GUI.
- Los scripts que necesiten menús o interfaces que no puedan integrarse se puedan abrir en **Konsole** cuando corresponda.

La GUI debe ejecutarse como **usuario normal**. Los scripts solicitan `sudo` cuando necesitan privilegios.

## Instalación del repositorio

Si todavía no tienes el proyecto:

```bash
git clone https://github.com/csr79a/fedora-plasma-setup.git
cd fedora-plasma-setup
```

Instala las dependencias de la GUI:

```bash
sudo dnf install -y python3 python3-pyqt6 sudo
```

## Ejecución de la GUI

Desde la raíz del repositorio:

```bash
python3 gui/fedora_setup_gui.py
```

También puedes darle permiso de ejecución y lanzarla directamente:

```bash
chmod +x gui/fedora_setup_gui.py
./gui/fedora_setup_gui.py
```

**No uses `sudo python3 gui/fedora_setup_gui.py`.**

---

## Acciones disponibles en la GUI

La ventana está organizada por categorías y cada acción ejecuta directamente el script correspondiente del repositorio.

### Sistema

**Configurar Fedora Plasma**

```bash
./plasma/setup-fedora-plasma.sh
```

Realiza la configuración general de Fedora Plasma, incluyendo actualización del sistema, DNF, RPM Fusion, multimedia, microcódigo, códecs AMD, swappiness y Flatpak/Flathub.

**Limpiar Fedora Plasma**

```bash
./plasma/cleanup-fedora-plasma.sh
```

Acción de limpieza independiente. La GUI la marca como acción potencialmente destructiva y solicita confirmación antes de ejecutarla.

### NVIDIA

**Instalar NVIDIA**

```bash
./nvidia/setup-nvidia.sh
```

Componente independiente para detectar la GPU NVIDIA, instalar/configurar el stack correspondiente y comprobar PRIME Render Offload cuando es posible.

### ASUS / ROG

**Instalar ASUS / ROG**

```bash
./asus/setup-asusctl.sh
```

Detecta hardware ASUS y, con confirmación, configura `asusctl`, `asusd`, `power-profiles-daemon` y opcionalmente ROG Control Center.

### Gaming

**Instalar gaming**

```bash
./gaming/setup-gaming-fedora.sh
```

Configura el entorno gaming, incluyendo Steam, ProtonPlus, Heroic Games Launcher, GameMode, MangoHud, GOverlay, `vm.max_map_count`, `ntsync` y `game-performance`.

La GUI no tiene un botón separado de limpieza para gaming porque el repositorio actualmente no contiene un `cleanup-gaming-fedora.sh`.

---

# Ejecución directa desde terminal

La GUI es opcional. Cada script puede ejecutarse directamente desde la raíz del repositorio.

Antes, si hace falta:

```bash
chmod +x plasma/setup-fedora-plasma.sh
chmod +x plasma/cleanup-fedora-plasma.sh
chmod +x nvidia/setup-nvidia.sh
chmod +x asus/setup-asusctl.sh
chmod +x gaming/setup-gaming-fedora.sh
```

### Configuración general

```bash
./plasma/setup-fedora-plasma.sh
```

### NVIDIA

```bash
./nvidia/setup-nvidia.sh
```

### ASUS / ROG

```bash
./asus/setup-asusctl.sh
```

### Gaming

```bash
./gaming/setup-gaming-fedora.sh
```

### Limpieza

```bash
./plasma/cleanup-fedora-plasma.sh
```

Los scripts son independientes y pueden ejecutarse por separado.

---

# Orden recomendado

Para una instalación nueva:

1. Actualiza Fedora y reinicia:
   ```bash
   sudo dnf upgrade --refresh
   sudo reboot
   ```
2. Ejecuta **Configurar Fedora Plasma**.
3. Si el equipo tiene NVIDIA, ejecuta **Instalar NVIDIA**.
4. Si el equipo es ASUS, ejecuta **Instalar ASUS / ROG**.
5. Reinicia cuando corresponda, especialmente después de instalar NVIDIA.
6. Ejecuta **Instalar gaming** si quieres preparar el equipo para jugar.
7. Ejecuta **Limpiar Fedora Plasma** solo si quieres realizar la limpieza opcional.

También puedes abrir la GUI después de clonar el repositorio y ejecutar las acciones una por una desde la ventana.

---

# Fedora: actualización inicial y conflictos de KMime

> Esta sección es exclusiva para Fedora.

En una instalación nueva de Fedora, se recomienda actualizar primero el sistema y reiniciar antes de continuar:

```bash
sudo dnf upgrade --refresh
sudo reboot
```

Si durante una instalación aparece un conflicto de RPM entre `kf6-kmime` y `kmime`, no borres archivos manualmente.

Primero sincroniza los paquetes:

```bash
sudo dnf distro-sync --refresh
```

Si Fedora solicita reiniciar:

```bash
sudo reboot
```

Para investigar el conflicto:

```bash
rpm -q kmime kf6-kmime
dnf repoquery --whatrequires kmime
dnf repoquery --whatrequires kf6-kmime
```

No se recomienda borrar archivos de `/usr/share` manualmente ni forzar una transacción con `--replacefiles` sin identificar antes la causa.

---

# Componentes

## Fedora Plasma

`plasma/setup-fedora-plasma.sh` configura la base del sistema:

- DNF y descargas paralelas.
- Actualización del sistema.
- RPM Fusion free/nonfree.
- Multimedia y FFmpeg.
- Microcódigo de CPU.
- Códecs AMD cuando corresponde.
- Swappiness.
- Flatpak/Flathub.

NVIDIA y ASUS se mantienen como componentes independientes.

## NVIDIA

`nvidia/setup-nvidia.sh` es independiente del setup general. Detecta la GPU NVIDIA e instala/configura el stack NVIDIA correspondiente.

Después de reiniciar, las comprobaciones habituales incluyen:

```bash
nvidia-smi
switcherooctl list
glxinfo | grep "OpenGL renderer"
nvidia-run glxinfo | grep "OpenGL renderer"
```

## ASUS / ROG

`asus/setup-asusctl.sh` detecta el fabricante mediante DMI. Si detecta ASUS, solicita confirmación antes de agregar el repositorio Terra e instalar las herramientas ASUS.

Puede instalar:

- `asusctl`
- `asusd`
- `power-profiles-daemon`
- ROG Control Center, opcionalmente

Si el equipo no es ASUS, el script termina sin realizar cambios.

## Gaming

`gaming/setup-gaming-fedora.sh` configura:

- RPM Fusion cuando es necesario.
- Steam.
- ProtonPlus.
- Heroic Games Launcher.
- GameMode.
- MangoHud.
- GOverlay.
- `vm.max_map_count`.
- `ntsync` cuando el kernel lo soporta.
- `game-performance`.

Ejemplo de uso para juegos:

```text
gamemoderun mangohud %command%
```

Y para el wrapper de rendimiento:

```text
game-performance gamemoderun mangohud %command%
```

---

# Notas importantes

- La GUI **no reemplaza** los scripts Bash: los ejecuta.
- La GUI no necesita `pyte`.
- Ejecuta la GUI y los scripts como usuario normal; utiliza `sudo` cuando sea necesario.
- Los scripts pueden volver a ejecutarse; comprueban el estado cuando corresponde y evitan sobrescribir configuraciones existentes de forma silenciosa.
- `vm.swappiness=60` coincide con el valor predeterminado habitual de Fedora y evita forzar swap en disco sin configurar zram; si ya existe una configuración propia en `/etc/sysctl.d/99-swappiness.conf`, el setup no la sobrescribe.
- NVIDIA y ASUS son componentes independientes del setup general.
- `cleanup-fedora-plasma.sh` puede eliminar paquetes: revisa la confirmación antes de aceptar.
- No se incluyen LACT, Cardwire ni Brave en la configuración automática del proyecto.

---

# Documentación

La documentación detallada de los componentes se encuentra en:

- [MANUAL.md](MANUAL.md)

El manual contiene la explicación paso a paso de Plasma, NVIDIA, ASUS/ROG y gaming.

---

# Migración

El componente de gaming que anteriormente estaba separado se mantiene integrado en este repositorio bajo:

```text
gaming/setup-gaming-fedora.sh
```

El script continúa siendo independiente del setup general de Plasma.
