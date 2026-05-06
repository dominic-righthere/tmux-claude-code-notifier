"""CLI entry point: python -m telegram {send|bot|setup}"""

import sys


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: python -m telegram {send|bot|setup}", file=sys.stderr)
        sys.exit(1)

    command = sys.argv[1]
    args = sys.argv[2:]

    if command == "send":
        from telegram.send import cli_main

        cli_main(args)
    elif command == "bot":
        from telegram.bot import cli_main

        cli_main(args)
    elif command == "setup":
        from telegram.setup import cli_main

        cli_main(args)
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        print("Usage: python -m telegram {send|bot|setup}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
