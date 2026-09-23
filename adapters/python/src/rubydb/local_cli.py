"""Lazy entry point: installing the network client never requires a server."""

import sys


def main():
    try:
        from rubydb_server.cli import main as server_main
    except ModuleNotFoundError as error:
        if error.name != "rubydb_server":
            raise
        print(
            'Local runtime missing. Install: python -m pip install "rubydb-python[local]"',
            file=sys.stderr,
        )
        return 2
    return server_main()


if __name__ == "__main__":
    sys.exit(main())
