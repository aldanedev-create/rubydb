"""Run installed-wheel tests with host Ruby and Go removed from PATH."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
environment = dict(os.environ)
environment.pop("PYTHONPATH", None)
environment["RUBYDB_LOCAL_LIVE"] = "1"
environment["RUBYDB_ACCELERATOR"] = "required"
# Deliberately invalid ambient gem settings must not leak into the runtime.
environment["GEM_HOME"] = str(repo / "tmp/nonexistent-host-gems")
environment["GEM_PATH"] = environment["GEM_HOME"]
environment["RUBYOPT"] = "-rthis_host_library_must_not_be_loaded"
environment["PATH"] = (
    str(Path(os.environ["SystemRoot"]) / "System32") if os.name == "nt" else ""
)
if shutil.which("ruby", path=environment["PATH"]) or shutil.which(
    "go", path=environment["PATH"]
):
    raise RuntimeError("Host tools are still on the verification PATH")
result = subprocess.run(
    [
        sys.executable,
        "-m",
        "unittest",
        "discover",
        "-s",
        str(repo / "packaging/python-server/tests"),
        "-v",
    ],
    env=environment,
)
sys.exit(result.returncode)
