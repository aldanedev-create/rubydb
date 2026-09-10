"""Create the example schema."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[2] / "adapters" / "python" / "src"))

from db import initialize_schema


if __name__ == "__main__":
    initialize_schema()
    print("RubyDB schema ready")
