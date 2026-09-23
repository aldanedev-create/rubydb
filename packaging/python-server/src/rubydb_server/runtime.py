"""Integrity-checked extraction of the bundled runtime; no network downloads."""

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from .files import exclusive, read_json

MAX_ARCHIVE_FILES = 20_000
MAX_ARCHIVE_BYTES = 1024 * 1024 * 1024


def digest(path):
    result = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


def safe_member(name):
    path = PurePosixPath(name)
    if (
        not name
        or path.is_absolute()
        or ".." in path.parts
        or "\\" in name
        or ":" in name
    ):
        raise RuntimeError("Unsafe runtime archive member")
    return path


class Runtime:
    def __init__(self, package=None, cache=None):
        self.package = Path(package) if package else Path(__file__).parent
        if not (self.package / "bundle.json").is_file():
            raise RuntimeError(
                "Runtime bundle missing; install a supported rubydb-server wheel"
            )
        self.metadata = read_json(self.package / "bundle.json")
        if self.metadata.get("format") != 1:
            raise RuntimeError("Unsupported runtime bundle format")
        archive_hash = self.metadata["sha256"]
        if len(archive_hash) != 64 or any(
            c not in "0123456789abcdef" for c in archive_hash
        ):
            raise RuntimeError("Invalid runtime archive hash")
        manifest_hash = self.metadata.get("manifest_sha256", "")
        if len(manifest_hash) != 64 or any(
            c not in "0123456789abcdef" for c in manifest_hash
        ):
            raise RuntimeError("Invalid runtime manifest hash")
        archive = self.package / "bundle.zip"
        if not archive.is_file() or digest(archive) != archive_hash:
            raise RuntimeError(
                "Bundled runtime checksum mismatch; reinstall rubydb-server"
            )
        base = Path(
            cache
            or os.environ.get("RUBYDB_RUNTIME_CACHE", Path.home() / ".cache/rubydb")
        )
        base.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.root = base / archive_hash
        with exclusive(base / "runtime.lock"):
            if not self.root.exists():
                self._extract(base, archive)
        if self.root.is_symlink():
            raise RuntimeError("Runtime cache root must not be a symbolic link")
        if digest(self.root / "manifest.json") != self.metadata["manifest_sha256"]:
            raise RuntimeError(
                "Cached runtime manifest checksum mismatch; use a fresh runtime cache"
            )
        self.inventory = read_json(self.root / "manifest.json")
        self.verify()

    def _extract(self, base, archive):
        with tempfile.TemporaryDirectory(
            prefix="rubydb-extract-", dir=base
        ) as temporary:
            staging = Path(temporary) / "runtime"
            staging.mkdir()
            try:
                source = zipfile.ZipFile(archive)
            except zipfile.BadZipFile as exc:
                raise RuntimeError(
                    "Bundled runtime is not a valid ZIP archive"
                ) from exc
            with source:
                members = source.infolist()
                if len(members) > MAX_ARCHIVE_FILES:
                    raise RuntimeError("Runtime archive contains too many files")
                if sum(member.file_size for member in members) > MAX_ARCHIVE_BYTES:
                    raise RuntimeError(
                        "Runtime archive expands beyond the safety limit"
                    )
                names = []
                casefolded = set()
                for member in members:
                    relative = safe_member(member.filename)
                    normalized = relative.as_posix()
                    folded = normalized.casefold()
                    if folded in casefolded:
                        raise RuntimeError("Runtime archive contains duplicate paths")
                    casefolded.add(folded)
                    names.append(normalized)
                    mode = member.external_attr >> 16
                    file_type = stat.S_IFMT(mode)
                    if stat.S_ISLNK(mode):
                        raise RuntimeError(
                            "Runtime archive must not contain symbolic links"
                        )
                    if member.flag_bits & 0x1:
                        raise RuntimeError(
                            "Runtime archive must not contain encrypted files"
                        )
                    if file_type and not member.is_dir() and not stat.S_ISREG(mode):
                        raise RuntimeError(
                            "Runtime archive contains a non-regular file"
                        )
                try:
                    manifest_bytes = source.read("manifest.json")
                    inventory = json.loads(manifest_bytes.decode("utf-8"))
                except (KeyError, UnicodeError, json.JSONDecodeError) as exc:
                    raise RuntimeError(
                        "Runtime archive has an invalid manifest"
                    ) from exc
                if digest_bytes(manifest_bytes) != self.metadata["manifest_sha256"]:
                    raise RuntimeError("Runtime archive manifest checksum mismatch")
                files = inventory.get("files")
                if (
                    inventory.get("format") != 1
                    or not isinstance(files, dict)
                    or len(files) > MAX_ARCHIVE_FILES
                ):
                    raise RuntimeError(
                        "Runtime archive has an unsupported file inventory"
                    )
                expected = set(files) | {"manifest.json"}
                actual = {
                    name for name, member in zip(names, members) if not member.is_dir()
                }
                if actual != expected:
                    raise RuntimeError(
                        "Runtime archive files do not match its manifest"
                    )
                for member, normalized in zip(members, names):
                    relative = PurePosixPath(normalized)
                    mode = member.external_attr >> 16
                    destination = staging.joinpath(*relative.parts)
                    if member.is_dir():
                        destination.mkdir(parents=True, exist_ok=True)
                        continue
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with (
                        source.open(member) as reader,
                        destination.open("wb") as writer,
                    ):
                        shutil.copyfileobj(reader, writer)
                    destination.chmod(0o755 if mode & 0o111 else 0o644)
            staging.rename(self.root)

    def verify(self):
        expected = set(self.inventory["files"]) | {"manifest.json"}
        actual = {
            path.relative_to(self.root).as_posix()
            for path in self.root.rglob("*")
            if path.is_file()
        }
        if actual != expected:
            raise RuntimeError(
                "Runtime cache contains unexpected or missing files; use a fresh runtime cache"
            )
        for name, expected in self.inventory["files"].items():
            relative = safe_member(name)
            path = self.root.joinpath(*relative.parts)
            if not path.is_file() or path.is_symlink() or digest(path) != expected:
                raise RuntimeError(
                    "Runtime file checksum mismatch: %s; reinstall or use a fresh runtime cache"
                    % name
                )

    @property
    def ruby(self):
        return self.root / self.inventory["ruby"]

    def environment(self):
        environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("RUBY", "GEM_", "BUNDLE_", "BUNDLER_"))
            and key
            not in {
                "LD_PRELOAD",
                "LD_LIBRARY_PATH",
                "DYLD_LIBRARY_PATH",
                "DYLD_INSERT_LIBRARIES",
            }
        }
        environment["GEM_HOME"] = str(self.root / "gems")
        environment["GEM_PATH"] = str(self.root / "gems")
        environment["RUBYLIB"] = os.pathsep.join(
            str(self.root / name) for name in self.inventory["load_paths"]
        )
        environment["RUBYDB_ACCELERATOR_BIN"] = str(
            self.root / self.inventory["accelerator"]
        )
        environment["RUBYDB_ACCELERATOR"] = os.environ.get("RUBYDB_ACCELERATOR", "auto")
        environment["PATH"] = os.pathsep.join(
            [str(self.ruby.parent), environment.get("PATH", "")]
        )
        if os.name != "nt":
            environment["LD_LIBRARY_PATH"] = str(self.root / "ruby/lib")
            if sys.platform == "darwin":
                environment["DYLD_LIBRARY_PATH"] = str(self.root / "ruby/lib")
        return environment

    def command(self, *args):
        return [str(self.ruby), *map(str, args)]

    def doctor(self):
        program = (
            'require "rubydb"; require "openssl"; require "json"; '
            'm = RubyDB::Accelerator::Manager.new(mode: "required"); '
            'begin; reply = m.request("ping"); '
            "puts JSON.generate({ruby: RUBY_VERSION, rubydb: RubyDB::VERSION, "
            "accelerator: reply, loaded_features: $LOADED_FEATURES.grep(/\\.(rb|so|dll)$/)}); "
            "ensure; m.close; end"
        )
        result = subprocess.run(
            self.command("-e", program),
            env=self.environment(),
            capture_output=True,
            text=True,
            timeout=60,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        if result.returncode:
            raise RuntimeError("Bundled runtime check failed: " + result.stderr[-4000:])
        report = json.loads(result.stdout.strip().splitlines()[-1])
        # A working developer machine must not hide missing packaged libraries.
        outside = [
            name
            for name in report.pop("loaded_features")
            if Path(name).is_absolute() and not self._inside(Path(name))
        ]
        if outside:
            raise RuntimeError(
                "Runtime loaded host files outside its bundle: " + ", ".join(outside)
            )
        return report

    def _inside(self, path):
        try:
            path.resolve().relative_to(self.root.resolve())
            return True
        except ValueError:
            return False
