"""Optional local RubyDB server. The engine runs in its own Ruby process."""

from ._version import __version__
from .local import LocalServer

__all__ = ["LocalServer", "__version__"]
