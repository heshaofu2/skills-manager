"""Check for available updates."""

from scripts import output, git_ops
from scripts.manifest import Manifest


def run(ctx, manifest: Manifest, args) -> None:
    output.header("Checking for updates")
    print()

    has_updates = False

    # Check repo-synced skills (by repo)
    for repo_key, repo_info in manifest.get_repos().items():
        branch = repo_info.get("branch", "main")
        repo_dir = ctx.repos_dir / manifest.repo_to_dir(repo_key)

        if not git_ops.is_git_repo(repo_dir):
            output.error(f"{repo_key}: not cloned yet")
            continue

        print(f"  Checking {repo_key}... ", end="", flush=True)
        git_ops.fetch(repo_dir, branch)

        local_commit = git_ops.get_head(repo_dir)
        try:
            remote_commit = git_ops._run("rev-parse", f"origin/{branch}", cwd=repo_dir)
        except git_ops.GitError:
            remote_commit = local_commit

        if local_commit != remote_commit:
            behind = git_ops.rev_list_count(repo_dir, "HEAD", f"origin/{branch}")
            print(output._c(output.YELLOW, f"{behind} new commit(s) in repo"))

            for sname, sdata in manifest.get_skills_for_repo(repo_key).items():
                subdir = sdata.get("subdir", "")
                synced = sdata.get("synced_commit", local_commit)
                if git_ops.has_diff(repo_dir, synced, f"origin/{branch}", subdir):
                    print(f"    \u2192 {output._c(output.YELLOW, sname)} has changes")
                    has_updates = True
                else:
                    print(f"    \u2192 {output._c(output.GREEN, sname)} unchanged")
        else:
            print(output._c(output.GREEN, "up to date"))

    # Check git-repo type skills
    for name in manifest.skill_names():
        if manifest.get_skill_type(name) != "git-repo":
            continue
        skill_path = manifest.get_skill_path(name)
        if not skill_path or not git_ops.is_git_repo(skill_path):
            continue

        print(f"  Checking {name} (git-repo)... ", end="", flush=True)
        branch = git_ops.get_current_branch(skill_path)
        git_ops.fetch(skill_path, branch)

        local_commit = git_ops.get_head(skill_path)
        try:
            remote_commit = git_ops._run("rev-parse", f"origin/{branch}", cwd=skill_path)
        except git_ops.GitError:
            remote_commit = local_commit

        if local_commit != remote_commit:
            behind = git_ops.rev_list_count(skill_path, "HEAD", f"origin/{branch}")
            print(output._c(output.YELLOW, f"{behind} new commit(s) available"))
            has_updates = True
        else:
            print(output._c(output.GREEN, "up to date"))

    print()
    if has_updates:
        print(f"Run {output._c(output.BLUE, 'python3 scripts/main.py pull')} to update.")
    else:
        print("All skills are up to date.")
