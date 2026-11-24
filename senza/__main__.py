"""Allow running `python3 -m senza`."""

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
