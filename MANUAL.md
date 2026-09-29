# Manual — fedora-plasma-setup

Este manual reúne la documentación de los componentes del repositorio. Cada componente sigue siendo independiente y puede ejecutarse por separado.

Estructura principal:

```text
fedora-plasma-setup/
├── gui/fedora_setup_gui.py
├── plasma/setup-fedora-plasma.sh
├── plasma/cleanup-fedora-plasma.sh
├── nvidia/setup-nvidia.sh
├── asus/setup-asusctl.sh
└── gaming/setup-gaming-fedora.sh
```

---

## GUI — Interfaz gráfica

La GUI se encuentra en:

```text
gui/fedora_setup_gui.py
```

Está desarrollada en **Python 3 + PyQt6**. Su función es ejecutar los scripts Bash reales del repositorio desde una interfaz gráfica; no contiene una segunda implementación de la lógica de instalación.

### Requisitos previos

Para utilizar la GUI se necesita:

- Fedora con un entorno gráfico funcional.
- Python 3.
- PyQt6.
- `sudo`.
- Los scripts del repositorio, conservando su estructura de directorios.

En Fedora, instalar los requisitos con:

```bash
sudo dnf install python3 python3-qt6 sudo
```

Comprobar la instalación:

```bash
python3 --version
python3 -c "import PyQt6; print('PyQt6 OK')"
```

### Ejecutar la GUI

Desde la raíz del repositorio:

```bash
python3 gui/fedora_setup_gui.py
```

También puede ejecutarse directamente:

```bash
./gui/fedora_setup_gui.py
```

La GUI usa un pseudo-terminal (PTY), de modo que los scripts pueden solicitar la contraseña de `sudo` y realizar preguntas interactivas como `[s/n]`. Las respuestas se introducen mediante el campo **Entrada** de la ventana.

### Uso

La ventana permite ejecutar por separado:

- Plasma
- NVIDIA
- ASUS / ROG
- Gaming
- Limpieza

Mientras un componente está ejecutándose, los demás botones quedan bloqueados. El botón **Detener** permite solicitar la terminación del proceso.

La GUI es opcional: los cinco componentes siguen siendo ejecutables directamente desde la terminal.

---

# Parte I — Fedora Plasma

# Manual — fedora-plasma-setup

Explicación detallada de cada paso del script, y de los pasos manuales que el script **no** hace por vos.

---

## Requisitos previos

- Fedora Workstation con KDE Plasma (spin oficial), instalación limpia recomendada.
- Usuario con permisos de `sudo` (no ejecutar el script como root).
- Conexión a internet.

---

## 1. dnf más rápido + base del sistema

Antes de actualizar nada, el script configura `/etc/dnf/dnf.conf` con:

- `max_parallel_downloads=10` — descarga varios paquetes a la vez en lugar de uno por uno.
- `fastestmirror=True` — elige automáticamente el mirror más rápido disponible.

Esto acelera notablemente el resto de la instalación (y cualquier `dnf install`/`update` posterior), sin efectos secundarios.

Después actualiza el sistema completo (`dnf update --refresh`, `dnf upgrade`) e instala:

- `fastfetch` — información del sistema en terminal
- `unrar`, `p7zip`, `p7zip-plugins` — soporte de compresión adicional
- `papirus-icon-theme` — tema de iconos

## 2. RPM Fusion y multimedia

Habilita los repositorios **RPM Fusion free y nonfree** (necesarios para códecs y drivers que Fedora no distribuye por licencia), actualiza los metadatos (`appstream-data`), reemplaza `ffmpeg-free` por `ffmpeg` completo, e instala el grupo `Multimedia` (excluyendo `PackageKit-gstreamer-plugin`, que puede generar conflictos con los códecs completos).

## 3. Microcódigo de CPU (automático)

El script lee `/proc/cpuinfo` para identificar el fabricante:

- **Intel** (`GenuineIntel`) → instala `microcode_ctl` (paquete separado, necesario).
- **AMD** (`AuthenticAMD`) → asegura que `linux-firmware` esté instalado/actualizado (ahí vienen los blobs de microcódigo AMD; a diferencia de Debian, no existe un paquete separado tipo `amd64-microcode`).

Esto es automático y no requiere confirmación — es información pura de compatibilidad, sin riesgo.

## 4. GPU y códecs AMD

La configuración general de Plasma conserva únicamente la gestión de códecs para GPU AMD. La configuración específica de NVIDIA se ha separado en el componente independiente `nvidia/setup-nvidia.sh`.

El script usa `lspci` para detectar GPU AMD:

- **AMD** → instala `mesa-va-drivers-freeworld` y, si está disponible, su variante i686 para aceleración de vídeo VAAPI.
- **NVIDIA** → la configuración del driver NVIDIA no se realiza desde este script. Debe ejecutarse por separado `nvidia/setup-nvidia.sh`.

En equipos híbridos con AMD + NVIDIA, el componente Plasma mantiene la parte general de AMD y el componente NVIDIA puede ejecutarse independientemente.

### Configuración NVIDIA

Para instalar/configurar NVIDIA, ejecutar desde la raíz:

```bash
./nvidia/setup-nvidia.sh
```

Ese componente detecta la GPU NVIDIA, instala `libva-nvidia-driver` y pregunta de forma independiente si se desea instalar el driver propietario mediante `akmod-nvidia` y CUDA.

## 5. Swappiness

Ajusta `vm.swappiness=150` mediante `/etc/sysctl.d/99-swappiness.conf`, aplicado con `sysctl --system`.

## 6. Flatpak → solo Flathub

Fedora trae por defecto un remoto Flatpak propio ("Fedora Flatpaks", que son los mismos RPM empaquetados como Flatpak, no builds independientes). El script:

```
flatpak remote-delete fedora --force
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
```

Esto aplica a nivel de sistema — funciona igual en KDE Plasma (Discover) que en GNOME (GNOME Software), no es específico de un escritorio.

## 7. Herramientas ASUS — componente independiente

El componente `asus/setup-asusctl.sh` lee `/sys/class/dmi/id/sys_vendor`. Si detecta un fabricante ASUS, **pregunta** antes de hacer nada (porque agrega un repo de terceros y reemplaza el gestor de energía del sistema):

Si confirmás:

1. Agrega el **repositorio Terra**:

```
sudo dnf install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release
```

2. Instala `asusctl` y activa `asusd.service`.
3. Reemplaza `tuned-ppd` por `power-profiles-daemon` (recomendado por el propio proyecto asusctl para evitar conflictos) y activa `power-profiles-daemon.service`.
4. Pregunta si además querés **ROG Control Center** (`asusctl-rog-gui`), la interfaz gráfica.

Si tu equipo **no** es ASUS, todo este bloque se salta automáticamente — no se toca nada.

### Cardwire: no incluido, instalación aparte

Cardwire — reemplazo comunitario de `supergfxd` para gestión de gráficos híbridos — se removió deliberadamente de este script. Motivos:

- El propio proyecto lo marca oficialmente como **experimental** ("rough edges" conocidos, soporte solo por Discord).
- En algunas configuraciones entra en conflicto con paquetes ya presentes en Fedora (como `switcheroo-control`), que cumple un rol similar.

Quien quiera instalarlo lo hace por su cuenta, siguiendo las instrucciones oficiales del proyecto: https://github.com/OpenGamingCollective/cardwire/releases

## 8. Limpieza de apps por defecto (`cleanup-fedora-plasma.sh`, script aparte)

Elimina, con confirmación previa, las siguientes aplicaciones si están instaladas:

**Heredadas del criterio usado en el proyecto de Debian:**

- KMail, Kontact, KTnef, KMouth, Konqueror, KAddressBook, Kontrast, exportador de preferencias PIM, KMouseTool, ImageMagick, editor de filtros Sieve

**Agregadas específicamente para este proyecto:**

- KMahjongg, KMines, KPatience (juegos)
- skanpage (escaneo), kamoso (cámara web)
- krfb (compartir escritorio — servidor), krdc (cliente de escritorio remoto)
- NeoChat (cliente Matrix)

El script solo actúa sobre paquetes realmente instalados; si alguno no está presente, se omite sin error. Pide confirmación antes de eliminar.

## No incluido en este proyecto

- **LACT** (curva de ventiladores GPU): se evaluó y se decidió dejarlo fuera por completo — quien lo necesite lo instala por su cuenta.
- **Brave**: se removió del script; instalalo aparte si lo querés (`curl -fsS https://dl.brave.com/install.sh | sh`).
- **Cardwire**: ver sección 7 más arriba.
- Verificación automática de Secure Boot: intencionalmente no se implementó; ver sección 4 para el proceso manual.


---

# Parte II — Gaming

# Manual — setup-gaming-fedora

Explicación detallada de cada paso del script.

---

## Requisitos previos

- Fedora Workstation con KDE Plasma, instalación limpia o ya en uso.
- Usuario con permisos de `sudo` (no ejecutar el script como root).
- Conexión a internet.

---

## 1. RPM Fusion

Steam en Fedora se instala desde RPM Fusion nonfree. El script comprueba si `rpmfusion-free-release` y `rpmfusion-nonfree-release` ya están instalados (por ejemplo, si ya corriste `setup-fedora-plasma.sh` antes) y, de ser así, **omite este paso por completo** sin tocar nada. Si falta alguno de los dos, lo instala.

## 2. Steam

Instala el paquete `steam` desde RPM Fusion. Si ya está instalado, se omite.

## 3. ProtonPlus

[ProtonPlus](https://github.com/Vysp3r/ProtonPlus) es una interfaz gráfica para gestionar builds de Proton-GE, Luxtorpeda, Wine-GE, etc. Se instala desde el repo COPR `wehagy/protonplus`:

```
sudo dnf copr enable wehagy/protonplus
sudo dnf install protonplus
```

El script comprueba si el COPR ya está habilitado y si el paquete ya está instalado antes de actuar.

## 4. Heroic Games Launcher (auto-actualización)

En vez de depender de un `.rpm` descargado a mano o de un COPR no oficial, el script:

1. Consulta `https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest`
2. Extrae la URL del asset que termina en `linux-x86_64.rpm` (el `.rpm` oficial publicado por el proyecto)
3. Compara la versión ahí publicada contra la versión instalada localmente (`rpm -q --qf '%{VERSION}' heroic`)
4. Si son iguales, no hace nada (`log_ok`, no vuelve a descargar)
5. Si son distintas (o no está instalado), descarga el `.rpm` a un archivo temporal y lo instala con `sudo dnf install -y`, que actualiza sobre la instalación previa si existía

Esto significa que **cada vez que corras el script**, Heroic queda en la última versión publicada, sin que tengas que ir manualmente a la página de releases. La configuración de Heroic (cuentas de Epic/GOG/Amazon logueadas, biblioteca, ajustes) vive en `~/.config/Heroic` — separada del paquete — así que no se pierde nada al reinstalar/actualizar.

### Por qué no Flatpak ni COPR

- **Flatpak** (`com.heroicgameslauncher.hgl`, oficial en Flathub) es una alternativa perfectamente válida y también se actualiza sola — si preferís esa vía en vez del `.rpm`, simplemente no corras este paso del script e instalá el Flatpak aparte.
- **COPR**: los repos comunitarios existentes para Heroic en Fedora (`atim/heroic-games-launcher`, `lnvso/heroic-games-launcher`) son **no oficiales**, mantenidos por terceros de forma discontinua — no se consideraron confiables a largo plazo para este script.

## 5. GameMode + MangoHud + GOverlay

- **GameMode** (`gamemode`, de Feral Interactive): aplica optimizaciones temporales de CPU/IO mientras un juego corre.
- **MangoHud**: overlay en juego con FPS, uso de CPU/GPU, temperaturas, etc.
- **GOverlay**: interfaz gráfica para configurar los perfiles de MangoHud (qué métricas mostrar, layout, posición, atajos de teclado, etc.) sin tener que editar `~/.config/MangoHud/MangoHud.conf` a mano. Se instala desde los repos oficiales de Fedora, sin necesidad de RPM Fusion ni COPR.

Para usarlos juntos, en las opciones de lanzamiento de un juego en Steam (o en el comando de Heroic/Lutris):

```
gamemoderun mangohud %command%
```

Y para editar la configuración de MangoHud gráficamente, simplemente abrí GOverlay desde el menú de aplicaciones.

## 6. `vm.max_map_count`

Varios juegos y motores modernos (por ejemplo Star Citizen, y otros con anti-cheat o mapeos de memoria intensivos) necesitan o se benefician de un límite más alto de `vm.max_map_count`. El script escribe:

```
vm.max_map_count=2147483642
```

en `/etc/sysctl.d/80-gamecompatibility.conf` (valor recomendado por Feral Interactive) y aplica el cambio con `sysctl --system`, sin necesidad de reiniciar.

## 7. ntsync

`ntsync` es un módulo de kernel (incorporado a partir del kernel 6.14) que mejora la sincronización de hilos que usa Proton/Wine, especialmente en juegos con anti-cheat o mucha concurrencia. El script:

1. Comprueba si el módulo ya está cargado (`lsmod`). Si ya lo está, y todavía no existe `/etc/modules-load.d/ntsync.conf`, lo crea igualmente — así queda garantizada la persistencia entre reinicios sin importar cómo se haya cargado el módulo la primera vez (por ejemplo, si lo cargaste manualmente antes de correr el script).
2. Si no está cargado, comprueba si el kernel actual lo trae (`modinfo ntsync`) y lo carga con `modprobe`.
3. Si logra cargarlo, agrega `/etc/modules-load.d/ntsync.conf` para que se cargue automáticamente en cada arranque.
4. Si el kernel no lo trae, avisa que hace falta actualizar el kernel — no es un error, solo una limitación de esa versión de kernel.

### Diagnóstico si el módulo no carga

Si ves `[WARN] No se pudo cargar el módulo ntsync`, comprobá:

```bash
uname -r                          # kernel 6.14 o superior
mokutil --sb-state                # si Secure Boot está activo y el módulo no está firmado/inscrito, se rechaza la carga
sudo modprobe ntsync
lsmod | grep ntsync
sudo dmesg | tail -n 30           # con sudo: dmesg sin sudo suele fallar por kernel.dmesg_restrict
```

Con Secure Boot desactivado y kernel ≥ 6.14, `ntsync` debería cargar sin problemas.

## 8. Alias de modo CPU performance

Agrega a `~/.bashrc` (con un marcador para no duplicarlos si corrés el script de nuevo):

```bash
alias gaming-on='powerprofilesctl set performance'
alias gaming-off='powerprofilesctl set balanced'
```

`gaming-on` fuerza el perfil de energía a rendimiento máximo (útil justo antes de jugar, sobre todo en laptops), y `gaming-off` lo vuelve a un perfil balanceado para el uso diario.

## Recomendaciones que el script no automatiza

- **Activar Steam Play para todos los títulos**: Steam → Configuración → Compatibilidad → "Habilitar Steam Play para todos los demás títulos", y elegir la versión de Proton por defecto (podés usar una de las que bajaste con ProtonPlus).
- **CoreCtrl / LACT** (overclock, fan curves): deliberadamente no incluidos, igual que en `fedora-plasma-setup` — quien lo necesite lo instala por su cuenta.

