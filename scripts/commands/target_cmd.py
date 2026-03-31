"""Manage target platforms."""

from scripts import output
from scripts.manifest import Manifest


def run_add(ctx, manifest: Manifest, args) -> None:
    name = args.name
    path = args.path

    if manifest.has_target(name):
        output.warn(f"Target '{name}' already exists")
        return

    expanded = manifest.expand_path(path)
    if not expanded.is_dir():
        expanded.mkdir(parents=True, exist_ok=True)
        output.success(f"Created directory: {expanded}")

    manifest.add_target(name, path)
    output.success(f"Target '{name}' added ({path})")


def run_remove(ctx, manifest: Manifest, args) -> None:
    name = args.name

    if not manifest.has_target(name):
        output.error(f"Target '{name}' not found")
        return

    manifest.remove_target(name)
    output.success(f"Target '{name}' removed.")
