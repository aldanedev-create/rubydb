"""Support ``python -m rubydb.server`` with the optional local runtime."""

import sys

from .local_cli import main

if __name__ == "__main__":
    sys.exit(main())
