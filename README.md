# fedora-plasma-setup

Script de configuración inicial para **Fedora Workstation / KDE Plasma spin**, pensado para dejar el equipo casi listo tras una instalación limpia: drivers multimedia, códecs por hardware (AMD/NVIDIA), microcódigo de CPU, Brave, Flathub y, si corresponde, herramientas ASUS ROG (asusctl).

Compañero de [`debian-trixie-setup`](https://github.com/csr79a/debian-trixie-setup), mismo enfoque adaptado a Fedora.

## Estructura

```
fedora-plasma-setup/
├── setup/
│   └── setup-fedora-plasma.sh     # Script principal de instalación
├── cleanup/
│   └── cleanup-fedora-plasma.sh   # Elimina apps de KDE no usadas (opcional, aparte)
├── README.md
└── MANUAL.md                      # Explicación detallada, paso a paso, y Secure Boot
```

## Qué hace `setup-fedora-plasma.sh`

1. Actualiza el sistema e instala paquetes base (fastfetch, unrar, p7zip, papirus-icon-theme)
2. Habilita RPM Fusion (free + nonfree) y configura multimedia completo (swap de ffmpeg, grupo Multimedia)
3. Detecta la CPU (Intel/AMD) e instala el microcódigo correspondiente, automáticamente
4. Detecta la GPU (AMD/NVIDIA) e instala los códecs VAAPI correspondientes, automáticamente; si hay NVIDIA, **pregunta** si instalar el driver propietario (akmod-nvidia)
5. Instala Brave (flavor origin) y ajusta `vm.swappiness=150`
6. Configura Flatpak para usar solo Flathub (elimina el remoto propio de Fedora)
7. Si detecta hardware ASUS, **pregunta** si instalar asusctl (repo Terra), ROG Control Center y Cardwire (experimental)
8. Muestra un resumen final con recomendaciones

El script es **idempotente**: se puede correr varias veces sin romper nada, y **no requiere hardware específico** — los bloques de NVIDIA y ASUS se saltan solos si no aplican.

## Qué hace `cleanup-fedora-plasma.sh`

Elimina, con confirmación previa, una lista de aplicaciones de KDE Plasma que vienen por defecto en el spin de Fedora y que normalmente no se usan (KMail, Konqueror, KMahjongg, KMines, KPatience, krfb, krdc, NeoChat, etc. — lista completa en `MANUAL.md`). Es un script **separado**, se corre aparte y por decisión propia.

## Uso rápido

```bash
git clone https://github.com/csr79a/fedora-plasma-setup.git
cd fedora-plasma-setup

chmod +x setup/setup-fedora-plasma.sh
./setup/setup-fedora-plasma.sh

# Opcional, aparte:
chmod +x cleanup/cleanup-fedora-plasma.sh
./cleanup/cleanup-fedora-plasma.sh
```

Ver `MANUAL.md` para el detalle de cada paso y, muy importante, el proceso manual de **Secure Boot / MOK enrollment** si instalás el driver propietario de NVIDIA.
