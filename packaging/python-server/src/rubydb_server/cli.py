"""Local development commands. Run the production service under a supervisor."""

import argparse
import json
import sys

from .local import LocalServer
from .runtime import Runtime


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="rubydb-python",
        description="Manage a local RubyDB server; no Ruby or Go install required",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("init", "start", "stop", "status", "url", "doctor"):
        command = commands.add_parser(name)
        command.add_argument("--data-dir", default=".rubydb")
        if name == "start":
            command.add_argument(
                "--port", type=int, default=0, help="0 selects an available port"
            )
            command.add_argument("--timeout", type=float, default=180)
        if name == "stop":
            command.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args(argv)
    try:
        server = LocalServer(args.data_dir)
        if args.command == "init":
            print("Initialized %s" % server.init())
        elif args.command == "start":
            server.start(port=args.port, timeout=args.timeout)
            print(json.dumps(server.status(), indent=2))
            print(
                'Get the private connection URL with: rubydb-python url --data-dir "%s"'
                % server.directory
            )
        elif args.command == "stop":
            server.stop(timeout=args.timeout)
            print("Stopped; database files retained")
        elif args.command == "status":
            report = server.status()
            print(json.dumps(report, indent=2))
            return 0 if report["state"] == "running" else 1
        elif args.command == "url":
            print(server.url)
        elif args.command == "doctor":
            print(
                json.dumps(
                    {"runtime": Runtime().doctor(), "instance": server.status()},
                    indent=2,
                )
            )
        return 0
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print("RubyDB: %s" % error, file=sys.stderr)
        return 1
