#!/usr/bin/env python3
"""
fedora_setup_gui.py
Interfaz gráfica para los componentes independientes de fedora-plasma-setup.

La GUI no contiene lógica de instalación: ejecuta los scripts Bash del proyecto
y muestra su salida en tiempo real.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from PyQt6.QtCore import QProcess, Qt
from PyQt6.QtGui import QFont
from PyQt6.QtWidgets import (
    QApplication,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QVBoxLayout,
    QWidget,
)


ROOT = Path(__file__).resolve().parent.parent

SCRIPTS = {
    "Plasma": ROOT / "plasma" / "setup-fedora-plasma.sh",
    "NVIDIA": ROOT / "nvidia" / "setup-nvidia.sh",
    "ASUS / ROG": ROOT / "asus" / "setup-asusctl.sh",
    "Gaming": ROOT / "gaming" / "setup-gaming-fedora.sh",
    "Limpieza": ROOT / "plasma" / "cleanup-fedora-plasma.sh",
}


class SetupWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.process: QProcess | None = None
        self.current_name = ""
        self.buttons: list[QPushButton] = []

        self.setWindowTitle("Fedora Plasma Setup")
        self.resize(900, 650)

        root = QWidget()
        self.setCentralWidget(root)
        layout = QVBoxLayout(root)

        title = QLabel("Fedora Plasma Setup")
        title.setFont(QFont("Sans", 20, QFont.Weight.Bold))
        layout.addWidget(title)

        subtitle = QLabel(
            "Componentes independientes · Plasma · NVIDIA · ASUS/ROG · Gaming · Limpieza"
        )
        subtitle.setWordWrap(True)
        layout.addWidget(subtitle)

        components = QGroupBox("Componentes")
        components_layout = QHBoxLayout(components)

        for name in ("Plasma", "NVIDIA", "ASUS / ROG", "Gaming", "Limpieza"):
            button = QPushButton(name)
            button.setMinimumHeight(48)
            button.clicked.connect(lambda checked=False, n=name: self.run_script(n))
            components_layout.addWidget(button)
            self.buttons.append(button)

        layout.addWidget(components)

        status = QHBoxLayout()
        self.status_label = QLabel("Listo")
        self.stop_button = QPushButton("Detener")
        self.stop_button.setEnabled(False)
        self.stop_button.clicked.connect(self.stop_process)
        status.addWidget(self.status_label)
        status.addStretch()
        status.addWidget(self.stop_button)
        layout.addLayout(status)

        self.output = QPlainTextEdit()
        self.output.setReadOnly(True)
        self.output.setFont(QFont("Monospace", 10))
        self.output.setPlaceholderText("La salida del script aparecerá aquí...")
        layout.addWidget(self.output, 1)

        info = QLabel(
            "Los scripts se ejecutan como tu usuario normal y usan sudo cuando necesitan privilegios."
        )
        info.setWordWrap(True)
        layout.addWidget(info)

    def set_buttons_enabled(self, enabled: bool) -> None:
        for button in self.buttons:
            button.setEnabled(enabled)

    def run_script(self, name: str) -> None:
        if self.process is not None:
            return

        script = SCRIPTS[name]
        if not script.is_file():
            QMessageBox.critical(
                self,
                "Script no encontrado",
                f"No se encontró:\n{script}",
            )
            return

        if shutil.which("sudo") is None:
            QMessageBox.critical(
                self,
                "sudo no disponible",
                "Este proyecto requiere sudo para ejecutar los componentes.",
            )
            return

        self.current_name = name
        self.output.clear()
        self.output.appendPlainText(f"$ {script.relative_to(ROOT)}")
        self.output.appendPlainText("")

        self.process = QProcess(self)
        self.process.setProgram("bash")
        self.process.setArguments([str(script)])
        self.process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        self.process.readyReadStandardOutput.connect(self.read_output)
        self.process.finished.connect(self.process_finished)
        self.process.errorOccurred.connect(self.process_error)

        self.set_buttons_enabled(False)
        self.stop_button.setEnabled(True)
        self.status_label.setText(f"Ejecutando: {name}…")
        self.process.start()

    def read_output(self) -> None:
        if self.process is None:
            return
        data = bytes(self.process.readAllStandardOutput()).decode(
            "utf-8", errors="replace"
        )
        if data:
            self.output.moveCursor(self.output.textCursor().MoveOperation.End)
            self.output.insertPlainText(data)
            self.output.ensureCursorVisible()

    def process_finished(self, exit_code: int, exit_status: QProcess.ExitStatus) -> None:
        self.read_output()
        name = self.current_name
        self.status_label.setText(
            f"{name}: finalizado correctamente" if exit_code == 0
            else f"{name}: terminó con código {exit_code}"
        )
        self.stop_button.setEnabled(False)
        self.set_buttons_enabled(True)

        if exit_code != 0:
            QMessageBox.warning(
                self,
                "Proceso finalizado",
                f"{name} terminó con código {exit_code}. Revisá la salida.",
            )

        self.process.deleteLater()
        self.process = None

    def process_error(self, error: QProcess.ProcessError) -> None:
        self.output.appendPlainText(f"\n[GUI] Error al ejecutar el proceso: {error.name}")

    def stop_process(self) -> None:
        if self.process is None:
            return

        answer = QMessageBox.question(
            self,
            "Detener proceso",
            "¿Querés detener el script que está ejecutándose?",
        )
        if answer == QMessageBox.StandardButton.Yes:
            self.process.terminate()
            if not self.process.waitForFinished(3000):
                self.process.kill()

    def closeEvent(self, event) -> None:
        if self.process is not None:
            answer = QMessageBox.question(
                self,
                "Proceso en ejecución",
                "Hay un script ejecutándose. ¿Querés salir igualmente?",
            )
            if answer != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.process.kill()
            self.process.waitForFinished(2000)
        event.accept()


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Fedora Plasma Setup")
    window = SetupWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
