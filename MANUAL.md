# Manual — fedora-plasma-setup

Explicación detallada de cada paso del script, y de los pasos manuales que el script **no** hace por vos.

---

## Requisitos previos

- Fedora Workstation con KDE Plasma (spin oficial), instalación limpia recomendada.
- Usuario con permisos de `sudo` (no ejecutar el script como root).
- Conexión a internet.

---

## 1. Base del sistema

Actualiza el sistema completo (`dnf update --refresh`, `dnf upgrade`) e instala:

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

## 4. GPU y códecs (automático + NVIDIA opcional)

El script usa `lspci` para detectar si hay GPU AMD, NVIDIA, o ambas (equipos híbridos):

- **AMD** → instala `mesa-va-drivers-freeworld` (+ variante i686 si está disponible) para aceleración de video VAAPI.
- **NVIDIA** → instala `libva-nvidia-driver` para códecs, y **pregunta** si querés instalar además el driver propietario completo (`akmod-nvidia` + `xorg-x11-drv-nvidia-cuda`).

El driver propietario NVIDIA se pregunta (no se instala solo) porque:
- Compila un módulo de kernel (`akmod`) la primera vez, lo cual tarda varios minutos.
- Si tenés **Secure Boot activado**, requiere un paso manual adicional (ver sección siguiente).

El script **no verifica si Secure Boot está activo** — es tu responsabilidad revisarlo si instalás el driver propietario.

### Secure Boot y MOK enrollment (paso manual, solo si instalaste akmod-nvidia)

Si tu equipo tiene Secure Boot **activado**, el módulo de NVIDIA no va a cargar hasta que lo firmes y lo aprobés manualmente. Si Secure Boot está **desactivado**, podés ignorar toda esta sección — el driver funciona directo tras reiniciar.

Pasos (a hacer vos, después de correr el script):

1. Verificar si Secure Boot está activo:
   ```bash
   mokutil --sb-state
   ```
2. Si está activo, tras instalar `akmod-nvidia`, la clave se genera automáticamente en `/etc/pki/akmods/certs/`.
3. Importar la clave al MOK (Machine Owner Key):
   ```bash
   sudo mokutil --import /etc/pki/akmods/certs/public_key.der
   ```
4. Te va a pedir crear una **contraseña temporal** (cualquiera, se usa una sola vez, en el siguiente paso).
5. Reiniciar el equipo:
   ```bash
   sudo reboot
   ```
6. Durante el arranque va a aparecer una pantalla azul de **MOK Management** (esto lo maneja el firmware, no Linux).
7. Elegir **"Enroll MOK"** → **"Continue"** → **"Yes"** → escribir la contraseña del paso 4.
8. El equipo termina de arrancar con el módulo NVIDIA cargado y confiado por Secure Boot.

Si no hacés este paso y Secure Boot está activo, el módulo `nvidia` simplemente no va a cargar (el sistema sigue funcionando, pero sin aceleración NVIDIA).

## 5. Brave y swappiness

- Instala Brave usando el instalador oficial (`curl -fsS https://dl.brave.com/install.sh | sh`), flavor *origin*.
- Ajusta `vm.swappiness=150` mediante `/etc/sysctl.d/99-swappiness.conf`, aplicado con `sysctl --system`.

## 6. Flatpak → solo Flathub

Fedora trae por defecto un remoto Flatpak propio ("Fedora Flatpaks", que son los mismos RPM empaquetados como Flatpak, no builds independientes). El script:

```bash
flatpak remote-delete fedora --force
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
```

Esto aplica a nivel de sistema — funciona igual en KDE Plasma (Discover) que en GNOME (GNOME Software), no es específico de un escritorio.

## 7. Herramientas ASUS (solo si se detecta hardware ASUS)

El script lee `/sys/class/dmi/id/sys_vendor`. Si detecta un fabricante ASUS, **pregunta** antes de hacer nada (porque agrega un repo de terceros y reemplaza el gestor de energía del sistema):

Si confirmás:
1. Agrega el **repositorio Terra**:
   ```bash
   sudo dnf install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release
   ```
2. Instala `asusctl` y activa `asusd.service`.
3. Reemplaza `tuned-ppd` por `power-profiles-daemon` (recomendado por el propio proyecto asusctl para evitar conflictos) y activa `power-profiles-daemon.service`.
4. Pregunta si además querés **ROG Control Center** (`asusctl-rog-gui`), la interfaz gráfica.
5. Pregunta, por separado y con advertencia, si querés instalar **Cardwire** — reemplazo comunitario de `supergfxd` para gestión de gráficos híbridos, marcado oficialmente como **experimental** ("rough edges" conocidos, soporte solo por Discord).

Si tu equipo **no** es ASUS, todo este bloque se salta automáticamente — no se toca nada.

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
- Verificación automática de Secure Boot: intencionalmente no se implementó; ver sección 4 para el proceso manual.
