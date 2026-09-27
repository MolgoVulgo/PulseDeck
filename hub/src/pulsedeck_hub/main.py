"""PulseDeck hub entry point.

Patch 0001 establishes the package skeleton only. Runtime services are added
in subsequent patches.
"""

from .logging_setup import configure_logging


def main() -> int:
    configure_logging()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
