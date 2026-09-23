"""Run against the installed wheel, with a real bundled RubyDB and Go worker.

Set RUBYDB_LOCAL_LIVE=1 after building/installing both wheels. No source path
injection here: these tests must exercise what a Python-only user installs.
"""

import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from rubydb import OperationalError, connect
from rubydb_server import LocalServer
from rubydb_server.files import exclusive, read_json, write_json
from rubydb_server.runtime import Runtime, safe_member


class PackagingSafetyTests(unittest.TestCase):
    def make_bundle(self, package, files, extra=None):
        package = Path(package)
        package.mkdir()
        inventory = {
            "format": 1,
            "ruby": "ruby/bin/ruby.exe",
            "accelerator": "engine/accelerator.exe",
            "load_paths": [],
            "files": {
                name: hashlib.sha256(value).hexdigest() for name, value in files.items()
            },
        }
        manifest = (json.dumps(inventory, indent=2) + "\n").encode()
        archive = package / "bundle.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
            output.writestr("manifest.json", manifest)
            for name, value in files.items():
                output.writestr(name, value)
            for name, value in (extra or {}).items():
                output.writestr(name, value)
        write_json(
            package / "bundle.json",
            {
                "format": 1,
                "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                "manifest_sha256": hashlib.sha256(manifest).hexdigest(),
            },
        )

    def test_reject_archive_path_escape(self):
        for name in ("../oops", "/absolute", "C:/windows", "a\\b", "a/../../b"):
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                safe_member(name)

    def test_lifecycle_lock_is_exclusive(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lock"
            with exclusive(path), self.assertRaises(RuntimeError):
                with exclusive(path):
                    pass

    def test_init_preserves_credentials_and_existing_data(self):
        with tempfile.TemporaryDirectory() as directory:
            server = LocalServer(directory)
            marker = Path(directory) / "keep.txt"
            marker.write_text("keep", encoding="utf-8")
            server.init()
            config = read_json(server.config_path)
            server.init()
            self.assertEqual(config, read_json(server.config_path))
            self.assertEqual(marker.read_text(), "keep")
            self.assertGreaterEqual(len(config["password"]), 64)

    def test_archive_inventory_rejects_unlisted_files(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package"
            self.make_bundle(package, {}, {"unexpected.exe": b"not listed"})
            with self.assertRaisesRegex(RuntimeError, "do not match"):
                Runtime(package=package, cache=Path(directory) / "cache")

    def test_cached_runtime_rejects_files_added_after_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package"
            cache = Path(directory) / "cache"
            self.make_bundle(package, {})
            runtime = Runtime(package=package, cache=cache)
            (runtime.root / "injected.rb").write_text(
                "raise 'injected'", encoding="utf-8"
            )
            with self.assertRaisesRegex(RuntimeError, "unexpected or missing"):
                Runtime(package=package, cache=cache)


@unittest.skipUnless(
    os.environ.get("RUBYDB_LOCAL_LIVE") == "1", "requires installed runtime wheel"
)
class LocalIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rubydb local test ")
        self.server = LocalServer(Path(self.temporary.name) / "data with spaces")

    def tearDown(self):
        self.server.stop()
        self.temporary.cleanup()

    def query(self, sql, params=None):
        with connect(self.server.url, timeout=5) as db:
            with db.cursor() as cursor:
                cursor.execute(sql, params)
                return cursor.fetchall()

    def test_install_start_transactions_restart_and_cli(self):
        self.server.start()
        first_pid = self.server.status()["pid"]
        # Starting the same data directory twice must reuse the healthy owner.
        self.assertEqual(LocalServer(self.server.directory).start(), self.server.url)
        self.assertEqual(self.server.status()["pid"], first_pid)
        self.query("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
        self.query("INSERT INTO notes (title) VALUES (?)", ["persistent from Python"])
        try:
            with connect(self.server.url) as db:
                db.execute("INSERT INTO notes (title) VALUES (?)", ["rolled back"])
                raise ValueError("abort transaction")
        except ValueError:
            pass
        self.assertEqual(
            self.query("SELECT title FROM notes"), [{"title": "persistent from Python"}]
        )
        with connect(self.server.url) as db:
            statement = db.prepare("SELECT title FROM notes WHERE title = ?")
            try:
                with statement.execute(["persistent from Python"]) as cursor:
                    self.assertEqual(
                        cursor.fetchone(), {"title": "persistent from Python"}
                    )
            finally:
                statement.close()
        status = subprocess.run(
            [
                sys.executable,
                "-m",
                "rubydb.server",
                "status",
                "--data-dir",
                str(self.server.directory),
            ],
            capture_output=True,
            text=True,
            timeout=15,
            check=True,
        )
        self.assertEqual(json.loads(status.stdout)["state"], "running")
        config = read_json(self.server.config_path)
        self.assertNotIn(config["password"], status.stdout)
        self.server.stop()
        self.assertEqual(self.server.process.returncode, 0)
        self.assertEqual(self.server.status()["state"], "stopped")
        self.server.start()
        self.assertEqual(
            self.query("SELECT title FROM notes"), [{"title": "persistent from Python"}]
        )

    def test_two_databases_get_distinct_ephemeral_ports(self):
        other = LocalServer(Path(self.temporary.name) / "second")
        try:
            self.server.start()
            other.start()
            self.assertNotEqual(self.server.status()["port"], other.status()["port"])
        finally:
            other.stop()

    def test_port_conflict_fails_and_releases_database(self):
        with socket.socket() as blocker:
            blocker.bind(("127.0.0.1", 0))
            blocker.listen()
            with self.assertRaisesRegex(RuntimeError, "exited during startup"):
                self.server.start(port=blocker.getsockname()[1])
        self.server.start()
        self.assertEqual(self.server.status()["state"], "running")

    def test_authentication_rejects_wrong_password(self):
        self.server.start()
        with self.assertRaises(OperationalError):
            connect(self.server.url, password="incorrect", timeout=2)
        self.assertEqual(self.server.status()["state"], "running")

    def test_crash_recovery_preserves_acknowledged_write(self):
        self.server.start()
        self.query("CREATE TABLE recovery (id INTEGER PRIMARY KEY, value TEXT)")
        self.query("INSERT INTO recovery (value) VALUES (?)", ["committed"])
        self.server.process.kill()
        self.server.process.wait(timeout=10)
        self.server.start()
        self.assertEqual(
            self.query("SELECT value FROM recovery"), [{"value": "committed"}]
        )

    def test_startup_timeout_cleans_up_child(self):
        with self.assertRaisesRegex(RuntimeError, "startup timed out"):
            self.server.start(timeout=0.001)
        self.assertIsNotNone(self.server.process.poll())
        self.server.start()
        self.assertEqual(self.server.status()["state"], "running")

    def test_bundled_go_and_ruby_load_without_host_tools(self):
        runtime = Runtime()
        self.assertEqual(runtime.doctor()["rubydb"], runtime.metadata["rubydb_version"])

    def test_detached_cli_lifecycle(self):
        command = [sys.executable, "-m", "rubydb.server"]
        data_dir = str(self.server.directory)
        started = subprocess.run(
            command + ["start", "--data-dir", data_dir],
            capture_output=True,
            text=True,
            timeout=90,
            check=True,
        )
        self.assertIn('"state": "running"', started.stdout)
        self.assertEqual(self.server.status()["state"], "running")
        subprocess.run(
            command + ["stop", "--data-dir", data_dir],
            capture_output=True,
            text=True,
            timeout=40,
            check=True,
        )
        self.assertEqual(self.server.status()["state"], "stopped")

    def test_tampered_archive_is_rejected_before_execution(self):
        installed = Path(
            __import__("rubydb_server.runtime", fromlist=["__file__"]).__file__
        ).parent
        package = Path(self.temporary.name) / "tampered"
        package.mkdir()
        write_json(package / "bundle.json", read_json(installed / "bundle.json"))
        (package / "bundle.zip").write_bytes(b"invalid archive")
        with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
            Runtime(package=package, cache=Path(self.temporary.name) / "isolated cache")


if __name__ == "__main__":
    unittest.main()
