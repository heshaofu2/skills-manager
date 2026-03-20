"""ANSI color output helpers."""

import sys

RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
NC = '\033[0m'

_use_color = sys.stdout.isatty()


def _c(color: str, msg: str) -> str:
    return f"{color}{msg}{NC}" if _use_color else msg


def info(msg: str) -> None:
    print(f"  {msg}")


def success(msg: str) -> None:
    print(f"  {_c(GREEN, msg)}")


def warn(msg: str) -> None:
    print(f"  {_c(YELLOW, msg)}")


def error(msg: str) -> None:
    print(f"  {_c(RED, msg)}")


def header(msg: str) -> None:
    print(f"{_c(BLUE, f'=== {msg} ===')}")


def skill_line(name: str, detail: str, color: str = GREEN) -> None:
    print(f"  {_c(color, name)} {detail}")
