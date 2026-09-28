# fedora-plasma-setup

Colección de scripts para preparar **Fedora Workstation / KDE Plasma**, manteniendo separadas la configuración general del sistema y la configuración específica para gaming.

## Estructura

```
fedora-plasma-setup/
├── plasma/
│   ├── setup-fedora-plasma.sh
│   └── cleanup-fedora-plasma.sh
├── gaming/
│   └── setup-gaming-fedora.sh
├── README.md
└── MANUAL.md
```

## Plasma

`plasma/setup-fedora-plasma.sh` realiza la configuración inicial de Fedora KDE Plasma: DNF, actualización del sistema, RPM Fusion, multimedia, microcódigo, códecs, NVIDIA opcional, swappiness, Flatpak/Flathub y herramientas ASUS cuando corresponde.

`plasma/cleanup-fedora-plasma.sh` es independiente y elimina, previa confirmación, aplicaciones de KDE que no se quieran conservar.

## Gaming

`gaming/setup-gaming-fedora.sh` es un componente independiente para gaming. Instala/configura Steam, ProtonPlus, Heroic Games Launcher, GameMode, MangoHud, GOverlay, `vm.max_map_count`, `ntsync` y los alias de rendimiento.

No es necesario ejecutar el script de gaming si solo se quiere preparar Fedora Plasma.

## Orden recomendado

Para una instalación nueva:

1. Ejecutar `plasma/setup-fedora-plasma.sh`.
2. Reiniciar si corresponde, especialmente después de instalar NVIDIA.
3. Ejecutar `gaming/setup-gaming-fedora.sh` si se quiere preparar el equipo para jugar.
4. Ejecutar `plasma/cleanup-fedora-plasma.sh` solo si se desea realizar la limpieza opcional.

Los scripts siguen siendo independientes y pueden ejecutarse por separado.

## Documentación

La documentación detallada de ambos componentes está reunida en [MANUAL.md](MANUAL.md).

## Migración

El componente que estaba en `setup-gaming-fedora` se ha integrado aquí bajo `gaming/`, manteniendo su script separado del setup de Plasma.
