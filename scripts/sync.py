"""File synchronization — symlink-first, copy as fallback."""

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


def is_symlinked(dest: Path, source: Path) -> bool:
    """Check if dest is a symlink pointing to source."""
    return dest.is_symlink() and dest.resolve() == source.resolve()


def sync_directory(source: Path, dest: Path) -> None:
    """Sync source to dest, mirroring `rsync -a --delete --exclude='.git'`.

    Legacy copy-based sync — kept as fallback for skills where symlink
    is not appropriate (e.g., subdir is '.' meaning whole repo).
    """
    if not source.is_dir():
        raise FileNotFoundError(f"Source not found: {source}")

    dest.mkdir(parents=True, exist_ok=True)

    # Copy source tree to dest, overwriting existing files
    shutil.copytree(source, dest, dirs_exist_ok=True, ignore=shutil.ignore_patterns('.git'))

    # Remove files in dest that don't exist in source
    _remove_orphans(source, dest)


def _remove_orphans(source: Path, dest: Path) -> None:
    """Remove files/dirs in dest that don't exist in source."""
    for item in sorted(dest.iterdir(), reverse=True):
        if item.name == '.git':
            continue
        source_item = source / item.name
        if not source_item.exists():
            if item.is_dir():
                shutil.rmtree(item)
            else:
                item.unlink()
        elif item.is_dir() and source_item.is_dir():
            _remove_orphans(source_item, item)
