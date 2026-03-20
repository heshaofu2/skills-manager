"""File synchronization — replaces rsync."""

import shutil
from pathlib import Path


def sync_directory(source: Path, dest: Path) -> None:
    """Sync source to dest, mirroring `rsync -a --delete --exclude='.git'`."""
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
