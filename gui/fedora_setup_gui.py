#!/usr/bin/env python3
"""
fedora_setup_gui.py
Interfaz gráfica para los componentes independientes de fedora-plasma-setup.

La GUI no contiene lógica de instalación: ejecuta los scripts Bash reales.
Usa un pseudo-terminal (PTY) para que sudo y los read -rp de los scripts
funcionen como en una terminal normal.
"""

from __future__ import annotations

import errno
import os
import pty
import signal
import shutil
import sys
from pathlib import Path

from PyQt6.QtCore import QSocketNotifier, QTimer, Qt
from PyQt6.QtGui import QFont
from PyQt6.QtWidgets import (
    QApplication,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
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
        self.pid: int | None = None
        self.master_fd: int | None = None
        self.notifier: QSocketNotifier | None = None
        self.current_name = ""

        self.setWindowTitle("Fedora Plasma Setup")
        self.resize(950, 700)

        root = QWidget()
        self.setCentralWidget(root)
        layout = QVBoxLayout(root)

        title = QLabel("Fedora Plasma Setup")
        title.setFont(QFont("Sans", 20, QFont.Weight.Bold))
        layout.addWidget(title)

        subtitle = QLabel(
            "Plasma · NVIDIA · ASUS/ROG · Gaming · Limpieza — componentes independientes"
        )
        subtitle.setWordWrap(True)
        layout.addWidget(subtitle)

        components = QGroupBox("Componentes")
        components_layout = QHBoxLayout(components)
        self.buttons: list[QPushButton] = []

        for name in SCRIPTS:
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

        input_row = QHBoxLayout()
        input_row.addWidget(QLabel("Entrada:"))
        self.input_line = QLineEdit()
        self.input_line.setPlaceholderText(
            "Contraseña de sudo o respuesta a una pregunta [s/n]"
        )
        self.input_line.setEchoMode(QLineEdit.EchoMode.Normal)
        self.input_line.returnPressed.connect(self.send_input)
        self.input_line.setEnabled(False)
        input_row.addWidget(self.input_line, 1)

        self.send_button = QPushButton("Enviar")
        self.send_button.setEnabled(False)
        self.send_button.clicked.connect(self.send_input)
        input_row.addWidget(self.send_button)
        layout.addLayout(input_row)

        info = QLabel(
            "La ejecución usa un pseudo-terminal, por lo que las preguntas de sudo "
            "y de los scripts pueden responderse desde esta ventana."
        )
        info.setWordWrap(True)
        layout.addWidget(info)

        self.poll_timer = QTimer(self)
        self.poll_timer.timeout.connect(self.poll_child)

    def set_buttons_enabled(self, enabled: bool) -> None:
        for button in self.buttons:
            button.setEnabled(enabled)

    def run_script(self, name: str) -> None:
        if self.pid is not None:
            return

        script = SCRIPTS[name]
        if not script.is_file():
            QMessageBox.critical(self, "Script no encontrado", f"No se encontró:\n{script}")
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
        self.output.appendPlainText(f"$ bash {script.relative_to(ROOT)}\n")

        try:
            pid, fd = pty.fork()
        except OSError as exc:
            QMessageBox.critical(self, "No se pudo crear el PTY", str(exc))
            return

        if pid == 0:
            os.execv("/bin/bash", ["/bin/bash", str(script)])

        self.pid = pid
        self.master_fd = fd
        self.notifier = QSocketNotifier(fd, QSocketNotifier.Type.Read, self)
        self.notifier.activated.connect(self.read_output)

        self.set_buttons_enabled(False)
        self.stop_button.setEnabled(True)
        self.input_line.setEnabled(True)
        self.send_button.setEnabled(True)
        self.status_label.setText(f"Ejecutando: {name}…")
        self.poll_timer.start(100)

    def read_output(self) -> None:
        if self.master_fd is None:
            return

        try:
            data = os.read(self.master_fd, 8192)
        except OSError as exc:
            if exc.errno not in (errno.EIO, errno.EBADF):
                self.output.appendPlainText(f"\n[GUI] Error leyendo PTY: {exc}")
            return

        if data:
            text = data.decode("utf-8", errors="replace")
            lower_text = text.lower()

            # Oculta la contraseña cuando sudo solicita credenciales.
            # Las respuestas normales ([s/n]) vuelven a mostrarse como texto.
            if "password" in lower_text or "contraseña" in lower_text:
                self.input_line.setEchoMode(QLineEdit.EchoMode.Password)
            elif "[s/n]" in lower_text or "[y/n]" in lower_text:
                self.input_line.setEchoMode(QLineEdit.EchoMode.Normal)

            self.output.moveCursor(self.output.textCursor().MoveOperation.End)
            self.output.insertPlainText(text)
            self.output.ensureCursorVisible()

    def send_input(self) -> None:
        if self.master_fd is None:
            return

        value = self.input_line.text()
        if not value:
            return

        try:
            os.write(self.master_fd, (value + "\n").encode())
        except OSError as exc:
            self.output.appendPlainText(f"\n[GUI] No se pudo enviar la entrada: {exc}")
        finally:
            self.input_line.clear()

    def poll_child(self) -> None:
        if self.pid is None:
            return

        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            pid, status = self.pid, 1

        if pid == 0:
            return

        exit_code = os.waitstatus_to_exitcode(status)
        name = self.current_name
        self.finish_process()

        if exit_code == 0:
            self.status_label.setText(f"{name}: finalizado correctamente")
        else:
            self.status_label.setText(f"{name}: terminó con código {exit_code}")
            QMessageBox.warning(
                self,
                "Proceso finalizado",
                f"{name} terminó con código {exit_code}. Revisá la salida.",
            )

    def finish_process(self) -> None:
        self.poll_timer.stop()

        if self.notifier is not None:
            self.notifier.setEnabled(False)
            self.notifier.deleteLater()
            self.notifier = None

        if self.master_fd is not None:
            try:
                os.close(self.master_fd)
            except OSError:
                pass
            self.master_fd = None

        self.pid = None
        self.stop_button.setEnabled(False)
        self.input_line.setEnabled(False)
        self.send_button.setEnabled(False)
        self.input_line.setEchoMode(QLineEdit.EchoMode.Normal)
        self.set_buttons_enabled(True)

    def stop_process(self) -> None:
        if self.pid is None:
            return

        answer = QMessageBox.question(
            self,
            "Detener proceso",
            "¿Querés detener el script que está ejecutándose?",
        )
        if answer != QMessageBox.StandardButton.Yes:
            return

        try:
            os.killpg(os.getpgid(self.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass

        QTimer.singleShot(1000, self.force_stop_if_running)

    def force_stop_if_running(self) -> None:
        if self.pid is None:
            return
        try:
            os.killpg(os.getpgid(self.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass

    def closeEvent(self, event) -> None:
        if self.pid is not None:
            answer = QMessageBox.question(
                self,
                "Proceso en ejecución",
                "Hay un script ejecutándose. ¿Querés detenerlo y salir?",
            )
            if answer != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            try:
                os.killpg(os.getpgid(self.pid), signal.SIGTERM)
            except ProcessLookupError:
                pass
            event.ignore()
            QTimer.singleShot(500, self.close)
            return

        event.accept()


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Fedora Plasma Setup")
    window = SetupWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
