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
        answer = input(f"Directory {path} does not exist. Create it? [y/N] ").strip()
        if answer.lower().startswith('y'):
            expanded.mkdir(parents=True, exist_ok=True)
        else:
            print("Aborted.")
            return

    manifest.add_target(name, path)
    output.success(f"Target '{name}' added ({path})")


def run_remove(ctx, manifest: Manifest, args) -> None:
    name = args.name

    if not manifest.has_target(name):
        output.error(f"Target '{name}' not found")
        return

    manifest.remove_target(name)
    output.success(f"Target '{name}' removed.")
