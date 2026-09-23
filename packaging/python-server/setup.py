"""A bundled executable requires a platform wheel, but no Python ABI."""

import json
from pathlib import Path
from setuptools import setup
from setuptools.command.bdist_wheel import bdist_wheel


class RuntimeWheel(bdist_wheel):
    def finalize_options(self):
        super().finalize_options()
        self.root_is_pure = False

    def get_tag(self):
        metadata = Path(__file__).parent / "src/rubydb_server/bundle.json"
        if not metadata.is_file():
            raise RuntimeError("Run scripts/build_python_server.py before building the runtime wheel")
        return "py3", "none", json.loads(metadata.read_text(encoding="utf-8"))["wheel_platform"]


setup(cmdclass={"bdist_wheel": RuntimeWheel})
