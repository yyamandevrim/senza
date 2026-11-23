"""Allow running `python3 -m dualmac`."""

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
