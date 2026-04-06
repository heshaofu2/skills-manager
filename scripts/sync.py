"""File synchronization — symlink-based."""

import shutil
from pathlib import Path


def ensure_symlink(source: Path, dest: Path) -> None:
    """Create a symlink from dest -> source.

    If dest already exists as a symlink pointing to source, do nothing.
    If dest is a real directory (old copy-based install), remove it and create symlink.
    """
    if not source.is_dir():
        raise FileNotFoundError(f"Source not found: {source}")

    if dest.is_symlink():
        if dest.resolve() == source.resolve():
            return  # Already correct
        dest.unlink()  # Wrong target, recreate
    elif dest.is_dir():
        shutil.rmtree(dest)  # Remove old copy-based directory

    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.symlink_to(source)
