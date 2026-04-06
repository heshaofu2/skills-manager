"""Uninstall a skill: remove from manifest and optionally delete files."""

import shutil

from scripts import output, git_ops
from scripts.manifest import Manifest


def run(ctx, manifest: Manifest, args) -> None:
    name = args.name
    keep_files = getattr(args, "keep_files", False)

    skill = manifest.get_skill(name)
    if not skill:
        output.error(f"Skill '{name}' not found in manifest")
        return

    path = skill.get("path", "")
    repo = skill.get("repo")
    expanded = manifest.expand_path(path) if path else None

    # Remove from manifest
    manifest.remove_skill(name)

    # Shrink sparse checkout if repo-synced
    if repo and manifest.has_repo(repo):
        repo_dir = ctx.repos_dir / manifest.repo_to_dir(repo)
        subdirs = [
            s.get("subdir", "")
            for s in manifest.get_skills_for_repo(repo).values()
            if s.get("subdir")
        ]
        if subdirs and git_ops.is_git_repo(repo_dir):
            git_ops.sparse_checkout_set(repo_dir, subdirs)

    # Delete files unless --keep-files
    if expanded and not keep_files:
        if expanded.is_symlink():
            expanded.unlink()  # Remove symlink only, not the source
            output.success(f"✓ {name} uninstalled (symlink removed: {expanded})")
        elif expanded.is_dir():
            shutil.rmtree(expanded)
            output.success(f"✓ {name} uninstalled (files deleted: {expanded})")
        else:
            output.success(f"✓ {name} removed from manifest")
    else:
        output.success(f"✓ {name} removed from manifest")
        if expanded and (expanded.is_dir() or expanded.is_symlink()):
            print(f"  Files kept at {expanded}")
