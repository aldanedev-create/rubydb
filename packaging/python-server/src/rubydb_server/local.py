"""Manage one local, loopback-only database owner per data directory."""

import os
import secrets
import subprocess
import time
from pathlib import Path
from urllib.parse import quote

from rubydb import connect

from .files import exclusive, read_json, write_json
from .runtime import Runtime


def process_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetExitCodeProcess.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(wintypes.DWORD),
        ]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return ctypes.get_last_error() == 5  # access denied: conservatively alive
        try:
            code = wintypes.DWORD()
            return (
                not kernel.GetExitCodeProcess(handle, ctypes.byref(code))
                or code.value == 259
            )
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class LocalServer:
    def __init__(self, data_dir=".rubydb"):
        self.directory = Path(data_dir).expanduser().resolve()
        self.control = self.directory / ".local"
        self.config_path = self.control / "config.json"
        self.state_path = self.control / "state.json"
        self.process = None

    def _prepare(self):
        self.control.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.control.chmod(0o700)

    def init(self):
        self._prepare()
        with exclusive(self.control / "command.lock"):
            self._initialize()
        return self.directory

    def _initialize(self):
        if not self.config_path.exists():
            write_json(
                self.config_path,
                {"format": 1, "username": "rubydb", "password": secrets.token_hex(32)},
            )
        config = read_json(self.config_path)
        if config.get("format") != 1 or not config.get("password"):
            raise RuntimeError("Unsupported or incomplete local instance configuration")
        return config

    def _state(self):
        return read_json(self.state_path) if self.state_path.exists() else None

    def _url(self, state):
        config = read_json(self.config_path)
        return "rubydb://%s:%s@127.0.0.1:%d/rubydb" % (
            quote(config["username"], safe=""),
            quote(config["password"], safe=""),
            state["port"],
        )

    @property
    def url(self):
        state = self._state()
        if not state or not state.get("ready") or not process_alive(state.get("pid")):
            raise RuntimeError("Local RubyDB is not running; run rubydb-python start")
        return self._url(state)

    def status(self):
        state = self._state()
        result = {"state": "stopped", "data_dir": str(self.directory)}
        if not state or not process_alive(state.get("pid")):
            return result
        result.update(state="unhealthy", pid=state["pid"], port=state.get("port"))
        if state.get("ready"):
            try:
                with connect(self._url(state), timeout=1) as connection:
                    connection.ping()
                result["state"] = "running"
            except Exception:
                pass  # Never echo configuration or credentials in diagnostics.
        return result

    def start(self, port=0, timeout=180):
        if not 0 <= int(port) <= 65535 or timeout <= 0:
            raise ValueError("port must be 0..65535 and timeout must be positive")
        self._prepare()
        with exclusive(self.control / "command.lock"):
            self._initialize()
            state = self._state()
            if state and process_alive(state.get("pid")):
                if self.status()["state"] == "running":
                    if port and port != state["port"]:
                        raise RuntimeError(
                            "Already running on another port; stop before changing ports"
                        )
                    return self.url
                raise RuntimeError(
                    "Existing instance is starting or unhealthy; inspect server.log before restarting"
                )
            runtime = Runtime()
            run_id = secrets.token_hex(16)
            request_path = self.control / "launch.json"
            write_json(
                request_path,
                {"run_id": run_id, "port": int(port), "data_dir": str(self.directory)},
            )
            # The child reads its own credentials from config.json, never argv.
            write_json(self.state_path, {"run_id": run_id, "pid": None, "ready": False})
            with (self.control / "server.log").open("ab") as log:
                self.process = subprocess.Popen(
                    runtime.command(
                        Path(__file__).with_name("server.rb"), request_path
                    ),
                    env=runtime.environment(),
                    cwd=self.directory,
                    stdin=subprocess.DEVNULL,
                    stdout=log,
                    stderr=log,
                    close_fds=True,
                    creationflags=(
                        subprocess.CREATE_NO_WINDOW
                        | subprocess.CREATE_NEW_PROCESS_GROUP
                    )
                    if os.name == "nt"
                    else 0,
                    start_new_session=os.name != "nt",
                )
            # Only the child publishes ready state; do not race its state write.
            deadline = time.monotonic() + timeout
            try:
                while time.monotonic() < deadline:
                    if self.process.poll() is not None:
                        raise RuntimeError(
                            "RubyDB exited during startup; see %s"
                            % (self.control / "server.log")
                        )
                    state = self._state()
                    if state and state.get("run_id") == run_id and state.get("ready"):
                        if self.status()["state"] == "running":
                            return self.url
                    time.sleep(0.1)
                raise RuntimeError(
                    "RubyDB startup timed out; see %s" % (self.control / "server.log")
                )
            except BaseException:
                self._request_stop(run_id)
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    # Only terminate the child we just created, never a saved PID.
                    self.process.terminate()
                    self.process.wait(timeout=10)
                raise

    def _request_stop(self, run_id):
        write_json(self.control / "stop.json", {"run_id": run_id})

    def stop(self, timeout=30):
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        if not self.control.exists():
            return
        with exclusive(self.control / "command.lock"):
            state = self._state()
            if not state or not process_alive(state.get("pid")):
                if self.process:
                    self.process.poll()
                return
            self._request_stop(state["run_id"])
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if not process_alive(state["pid"]):
                    # Reap a child started by this manager. On Windows this
                    # also releases any inherited file handles before a caller
                    # can restart or remove its data directory.
                    if self.process and self.process.pid == state["pid"]:
                        self.process.wait(timeout=max(0.1, deadline - time.monotonic()))
                    return
                time.sleep(0.1)
            raise RuntimeError(
                "Graceful stop timed out; inspect server.log. The process was not forcibly killed"
            )
