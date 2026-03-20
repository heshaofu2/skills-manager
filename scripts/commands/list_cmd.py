"""List all skills and their status."""

from scripts import output
from scripts.manifest import Manifest
from scripts import git_ops


def run(ctx, manifest: Manifest, args) -> None:
    output.header("All Skills")

    targets = manifest.get_targets()
    target_names = ", ".join(targets.keys())
    print(f"  Targets: {output._c(output.GREEN, target_names)}")
    print()

    # Collect all skill names (from manifest + targets)
    from scripts.scanner import collect_skills_from_targets
    all_names = set(manifest.skill_names())
    all_names.update(collect_skills_from_targets(targets))

    for name in sorted(all_names):
        skill = manifest.get_skill(name)
        if not skill:
            print(f"  {output._c(output.RED, name)} [unmanaged]")
            continue

        stype = manifest.get_skill_type(name)
        path = skill.get("path", "")
        pinned = skill.get("pinned", False)
        pin_marker = " [PINNED]" if pinned else ""

        # Check path existence
        path_status = ""
        if path:
            expanded = manifest.expand_path(path)
            if not expanded.exists():
                path_status = f" {output._c(output.RED, '[MISSING]')}"

        if stype == "git-repo":
            commit = ""
            expanded = manifest.expand_path(path)
            if git_ops.is_git_repo(expanded):
                commit = git_ops.get_head_short(expanded)
            print(f"  {output._c(output.GREEN, name)} (git-repo) [{commit}] {path}{path_status}{pin_marker}")

        elif stype == "repo-synced":
            repo = skill.get("repo", "")
            subdir = skill.get("subdir", "")
            commit = ""
            repo_dir = ctx.repos_dir / manifest.repo_to_dir(repo)
            if git_ops.is_git_repo(repo_dir):
                commit = git_ops.get_head_short(repo_dir)
            print(f"  {output._c(output.GREEN, name)} \u2192 {repo}/{subdir} [{commit}] {path}{path_status}{pin_marker}")

        elif stype == "local":
            note = skill.get("note", "")
            print(f"  {output._c(output.YELLOW, name)} (local) {path} {note}")

    print()
