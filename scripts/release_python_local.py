"""Validate exact local-runtime wheels, then optionally publish verified files.

First run without arguments. After validation, --publish checks the recorded
artifact hashes and uploads only these two wheels (never older dist files).
Twine handles credentials through the user's terminal/keyring/environment.
"""

import argparse
import datetime
import hashlib
import json
import runpy
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT_VERSION = runpy.run_path(ROOT / "adapters/python/src/rubydb/_version.py")[
    "__version__"
]
SERVER_VERSION = runpy.run_path(
    ROOT / "packaging/python-server/src/rubydb_server/_version.py"
)["__version__"]
CLIENT = ROOT / (
    "adapters/python/dist/rubydb_python-%s-py3-none-any.whl" % CLIENT_VERSION
)
SERVER = ROOT / (
    "packaging/python-server/dist/rubydb_server-%s-py3-none-win_amd64.whl"
    % SERVER_VERSION
)
REPORT = ROOT / "packaging/python-server/dist/release-validation.json"


def checksum(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    for artifact in (CLIENT, SERVER):
        if not artifact.is_file():
            parser.error(
                "Missing wheel: %s. Follow packaging/python-server/README.md to build it"
                % artifact
            )
    hashes = {artifact.name: checksum(artifact) for artifact in (CLIENT, SERVER)}
    run(sys.executable, "-m", "twine", "check", CLIENT, SERVER)
    if args.publish:
        if not REPORT.is_file():
            parser.error(
                "Run this script without --publish first to test the installed wheels"
            )
        report = json.loads(REPORT.read_text(encoding="utf-8"))
        if report.get("sha256") != hashes or report.get("tests_passed") is not True:
            parser.error("Artifacts changed or validation failed; run validation again")
        print(
            "Uploading the validated Windows x64 runtime and Python client to PyPI.",
            flush=True,
        )
        print(
            "Create/manage a token at https://pypi.org/manage/account/token/ and use Twine's private prompt.",
            flush=True,
        )
        run(
            sys.executable,
            "-m",
            "twine",
            "upload",
            "--repository-url",
            "https://upload.pypi.org/legacy/",
            SERVER,
            CLIENT,
        )
    else:
        with tempfile.TemporaryDirectory(
            prefix="rubydb-wheel-validation-"
        ) as temporary:
            venv = Path(temporary) / "venv"
            run(sys.executable, "-m", "venv", venv)
            python = venv / (
                "Scripts/python.exe" if sys.platform == "win32" else "bin/python"
            )
            run(
                python,
                "-m",
                "pip",
                "install",
                "--no-index",
                "--find-links",
                CLIENT.parent,
                "--find-links",
                SERVER.parent,
                "rubydb-python[local]==0.1.1",
            )
            run(python, ROOT / "scripts/verify_python_local.py")
        report = {
            "tests_passed": True,
            "sha256": hashes,
            "validated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "python": sys.version,
            "platform": sys.platform,
        }
        REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(
            "Validated both wheels. Publish with: python scripts/release_python_local.py --publish",
            flush=True,
        )


if __name__ == "__main__":
    main()
