"""Remove a skill from manifest."""

from scripts import output
from scripts.manifest import Manifest


def run(ctx, manifest: Manifest, args) -> None:
    name = args.name

    skill = manifest.get_skill(name)
    if not skill:
        output.error(f"Skill '{name}' not found in manifest")
        return

    path = skill.get("path", "")
    repo = skill.get("repo")

    manifest.remove_skill(name)

    # Shrink sparse checkout if repo-synced
    if repo:
        repo_dir = ctx.repos_dir / manifest.repo_to_dir(repo)
        subdirs = [s.get("subdir", "") for s in manifest.get_skills_for_repo(repo).values() if s.get("subdir")]
        if subdirs:
            from scripts import git_ops
            git_ops.sparse_checkout_set(repo_dir, subdirs)

    output.success(f"Skill '{name}' removed from manifest.")
    if path:
        expanded = manifest.expand_path(path)
        print(f"  Files at {expanded} were NOT deleted.")
