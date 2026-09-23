"""Build a platform runtime from an installed Ruby, without packaging user gems.

Run on each target OS/architecture. The relocation check rejects host-library
dependencies. Linux/macOS builders must provide a relocatable Ruby prefix with
its shared library dependencies; a Windows RubyInstaller prefix works directly.
The resulting Linux wheel is intentionally linux_* until audited for manylinux.
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PACKAGE = REPO / "packaging/python-server/src/rubydb_server"


def sha256(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def copy_tree(source, target):
    shutil.copytree(
        source,
        target,
        dirs_exist_ok=True,
        ignore=shutil.ignore_patterns(".git", "__pycache__", "*.gem", "*.o", "*.a"),
    )


def build(ruby):
    print("Inspecting Ruby runtime dependencies", flush=True)
    # A release must reflect this checkout, never an already-installed rubydb
    # gem or an application's Bundler environment.
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("BUNDLE_", "BUNDLER_", "GEM_", "RUBYDB_"))
        and key not in ("RUBYOPT", "RUBYLIB")
    }
    info = json.loads(
        subprocess.check_output(
            [ruby, str(REPO / "packaging/python-server/inspect_runtime.rb"), str(REPO)],
            env=environment,
            text=True,
        )
    )
    prefix = Path(info["prefix"])
    machine = platform.machine().lower()
    arch = {
        "amd64": "amd64",
        "x86_64": "amd64",
        "arm64": "arm64",
        "aarch64": "arm64",
    }.get(machine)
    system = {"Windows": "windows", "Darwin": "darwin", "Linux": "linux"}.get(
        platform.system()
    )
    if not arch or not system:
        raise RuntimeError("Unsupported target: %s/%s" % (platform.system(), machine))
    if (
        arch == "amd64" and not any(x in info["platform"] for x in ("x64", "x86_64"))
    ) or (
        arch == "arm64" and not any(x in info["platform"] for x in ("arm64", "aarch64"))
    ):
        raise RuntimeError(
            "Ruby and Python architectures differ; build with matching interpreters"
        )
    binary_name = "rubydb-accelerator-%s-%s%s" % (
        system,
        arch,
        ".exe" if system == "windows" else "",
    )
    accelerator = REPO / "accelerator/bin" / binary_name
    if not accelerator.is_file():
        raise RuntimeError("Build the target Go accelerator first: " + binary_name)
    checksums = dict(
        line.split()[::-1]
        for line in (REPO / "accelerator/bin/SHA256SUMS").read_text().splitlines()
        if line.strip()
    )
    if checksums.get(binary_name) != sha256(accelerator):
        raise RuntimeError("Go accelerator checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="rubydb-runtime-build-") as temporary:
        root = Path(temporary) / "payload"
        runtime = root / "ruby"
        print("Copying Ruby standard library and native dependencies", flush=True)
        (runtime / "bin").mkdir(parents=True)
        ruby_name = "ruby.exe" if os.name == "nt" else "ruby"
        shutil.copy2(info["ruby"], runtime / "bin" / ruby_name)
        if os.name == "nt":
            for dll in (prefix / "bin").glob("*.dll"):
                shutil.copy2(dll, runtime / "bin" / dll.name)
            builtin = prefix / "bin/ruby_builtin_dlls"
            if builtin.is_dir():
                copy_tree(builtin, runtime / "bin/ruby_builtin_dlls")
        else:
            (runtime / "lib").mkdir(exist_ok=True)
            for library in (prefix / "lib").iterdir():
                if library.is_file() and (
                    ".so" in library.name or library.suffix == ".dylib"
                ):
                    shutil.copy2(library, runtime / "lib" / library.name)
        # Include Ruby standard library/default gem specifications, but exclude
        # arbitrary installed gems, credentials, developer tools and gem caches.
        shutil.copytree(
            prefix / "lib/ruby",
            runtime / "lib/ruby",
            ignore=shutil.ignore_patterns("gems", "*.a", "*.o"),
        )
        # RubyGems still probes the compiled-in default gem directory even
        # though the packaged runtime uses GEM_HOME below. Keep that directory
        # present so every local startup is quiet and deterministic.
        (
            runtime
            / "lib/ruby/gems"
            / info["ruby_api_version"]
            / "specifications/default"
        ).mkdir(parents=True, exist_ok=True)
        (root / "licenses").mkdir()
        shutil.copy2(REPO / "LICENSE", root / "licenses/RubyDB-LICENSE.txt")
        ruby_licenses = [
            path
            for pattern in ("LICENSE*", "COPYING*", "BSDL*")
            for path in prefix.glob(pattern)
            if path.is_file()
        ]
        if not ruby_licenses:
            raise RuntimeError("Ruby prefix must contain Ruby redistribution licenses")
        for path in ruby_licenses:
            shutil.copy2(path, root / "licenses" / ("Ruby-" + path.name))
        for directory in (prefix / "share/licenses", prefix / "share/doc"):
            if directory.is_dir():
                # Ruby's generated API documentation can exceed 200 MB. Ship
                # the license/legal notices, not that unrelated documentation.
                for notice in directory.rglob("*"):
                    if notice.is_file() and any(
                        token in notice.name.upper()
                        for token in (
                            "LICENSE",
                            "COPYING",
                            "LEGAL",
                            "BSDL",
                            "COPYRIGHT",
                        )
                    ):
                        target = (
                            root
                            / "licenses"
                            / directory.name
                            / notice.relative_to(directory)
                        )
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(notice, target)
        for directory in (
            prefix / "msys64/ucrt64/share/licenses",
            prefix / "msys64/mingw64/share/licenses",
        ):
            if directory.is_dir():
                copy_tree(directory, root / "licenses/native-dependencies")
        go = shutil.which("go")
        if not go and Path("C:/Program Files/Go/bin/go.exe").is_file():
            go = "C:/Program Files/Go/bin/go.exe"
        if not go:
            raise RuntimeError(
                "Go is required on the builder to collect its redistribution license"
            )
        goroot = Path(subprocess.check_output([go, "env", "GOROOT"], text=True).strip())
        shutil.copy2(goroot / "LICENSE", root / "licenses/Go-LICENSE.txt")
        gem_root = root / "gems"
        for gem in info["gems"]:
            source = Path(gem["source"])
            if source.is_dir():
                copy_tree(source, gem_root / "gems" / source.name)
            specification = Path(gem["specification"])
            destination = gem_root / "specifications"
            if gem["default"]:
                destination /= "default"
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copy2(specification, destination / specification.name)
            extension = Path(gem["extension"])
            if gem["has_extensions"] and extension.is_dir():
                # Preserve extensions/<platform>/<ruby-abi>/<gem> layout.
                copy_tree(
                    extension,
                    gem_root
                    / "extensions"
                    / extension.parent.parent.name
                    / extension.parent.name
                    / extension.name,
                )
        copy_tree(REPO / "lib", root / "engine/lib")
        print("Writing runtime inventory and compressed bundle", flush=True)
        binary_dir = root / "engine/accelerator/bin"
        binary_dir.mkdir(parents=True)
        shutil.copy2(accelerator, binary_dir / binary_name)
        (binary_dir / binary_name).chmod(0o755)
        (binary_dir / "SHA256SUMS").write_text(
            "%s  %s\n" % (sha256(accelerator), binary_name), encoding="utf-8"
        )
        load_paths = ["engine/lib"] + [
            "ruby/" + Path(path).relative_to(prefix).as_posix()
            for path in info["load_paths"]
        ]
        manifest = {
            "format": 1,
            "ruby": "ruby/bin/" + ruby_name,
            "ruby_version": info["ruby_version"],
            "ruby_api_version": info["ruby_api_version"],
            "rubydb_version": info["rubydb_version"],
            "accelerator": "engine/accelerator/bin/" + binary_name,
            "load_paths": load_paths,
            "gems": [
                {key: gem[key] for key in ("name", "version", "licenses")}
                for gem in info["gems"]
            ],
            "files": {
                path.relative_to(root).as_posix(): sha256(path)
                for path in sorted(root.rglob("*"))
                if path.is_file()
            },
        }
        manifest_path = root / "manifest.json"
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        candidate = Path(temporary) / "candidate"
        candidate.mkdir()
        with zipfile.ZipFile(
            candidate / "bundle.zip", "w", zipfile.ZIP_DEFLATED, compresslevel=6
        ) as archive:
            for path in sorted(root.rglob("*")):
                if path.is_dir():
                    archive.write(path, path.relative_to(root).as_posix() + "/")
                else:
                    archive.write(path, path.relative_to(root).as_posix())
        metadata = {
            "format": 1,
            "wheel_platform": sysconfig.get_platform()
            .replace("-", "_")
            .replace(".", "_"),
            "rubydb_version": info["rubydb_version"],
            "ruby_version": info["ruby_version"],
            "ruby_api_version": info["ruby_api_version"],
            "sha256": sha256(candidate / "bundle.zip"),
            "manifest_sha256": sha256(manifest_path),
        }
        (candidate / "bundle.json").write_text(
            json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
        )
        sys.path.insert(0, str(REPO / "adapters/python/src"))
        sys.path.insert(0, str(PACKAGE.parent))
        from rubydb_server.runtime import Runtime

        # Actually relocate, extract and execute; a developer's Ruby on PATH
        # must not make an incomplete bundle appear to pass.
        bundled = Runtime(
            package=candidate, cache=Path(temporary) / "relocated runtime"
        )
        print("Checking relocated Ruby and Go execution", flush=True)
        report = bundled.doctor()
        for name in ("bundle.zip", "bundle.json"):
            shutil.copy2(candidate / name, PACKAGE / name)
        print(
            json.dumps(
                {
                    "runtime": report,
                    "bundle": metadata,
                    "size_bytes": (PACKAGE / "bundle.zip").stat().st_size,
                },
                indent=2,
            )
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ruby", default=shutil.which("ruby"))
    args = parser.parse_args()
    if not args.ruby:
        parser.error(
            "Ruby is required on the build machine; users of the wheel do not need Ruby"
        )
    build(args.ruby)
