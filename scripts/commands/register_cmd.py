"""Register a specific unmanaged skill by name."""

from scripts import output, git_ops
from scripts.manifest import Manifest
from scripts.scanner import (
    detect_clawhub,
    detect_skill_nature,
    find_in_repos,
    find_skill_in_targets,
)


def run(ctx, manifest: Manifest, args) -> None:
    name = args.name

    if manifest.has_skill(name):
        output.warn(f"Skill '{name}' is already registered")
        return

    # Find the skill in target directories
    targets = manifest.get_targets()
    found = find_skill_in_targets(name, targets)
    if not found:
        output.error(f"Skill '{name}' not found in any target directory")
        return

    _, entry = found
    actual_dir = entry.resolve() if entry.is_symlink() else entry
    mpath = manifest.to_manifest_path(entry)

    # Classify and register
    if actual_dir.is_dir() and git_ops.is_git_repo(actual_dir):
        remote_url = git_ops.get_remote_url(actual_dir) or ""
        actual_mpath = manifest.to_manifest_path(actual_dir)
        data = {"path": actual_mpath, "type": "git-repo", "pinned": False}
        if remote_url:
            data["repo_url"] = remote_url
        manifest.add_skill(name, data)
        output.success(f"✓ {name} registered as git-repo")
        return

    if actual_dir.is_dir():
        clawhub = detect_clawhub(actual_dir)
        if clawhub:
            manifest.add_skill(name, {
                "path": mpath,
                "type": "clawhub",
                "clawhub_slug": clawhub.get("slug", name),
                "clawhub_version": clawhub.get("installedVersion", "?"),
                "clawhub_registry": clawhub.get("registry", "https://clawhub.ai"),
                "pinned": False,
            })
            output.success(f"✓ {name} registered as clawhub")
            return

    match = find_in_repos(name, ctx.repos_dir, manifest)
    if match:
        manifest.add_skill(name, {"path": mpath, "repo": match[0], "subdir": match[1], "pinned": False})
        output.success(f"✓ {name} registered as repo-synced ({match[0]})")
        return

    # Fallback: local
    note = ""
    if actual_dir.is_dir():
        nature = detect_skill_nature(actual_dir)
        if nature.kind == "private":
            note = f"Private: {nature.detail}"
        elif nature.kind == "has-source-url":
            note = f"Source: {nature.detail}"

    data = {"path": mpath, "repo": None}
    if note:
        data["note"] = note
    manifest.add_skill(name, data)
    output.success(f"✓ {name} registered as local{f' ({note})' if note else ''}")
