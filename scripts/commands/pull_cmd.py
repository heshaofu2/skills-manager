"""Pull updates and sync to skill paths."""

from scripts import output, git_ops
from scripts.manifest import Manifest
from scripts.sync import sync_directory


def run(ctx, manifest: Manifest, args) -> None:
    target = getattr(args, "target", "") or ""

    if target:
        _pull_target(ctx, manifest, target)
    else:
        _pull_all(ctx, manifest)


def _pull_target(ctx, manifest: Manifest, target: str) -> None:
    # Target could be a repo name or a skill name
    if manifest.has_repo(target):
        _pull_repo(ctx, manifest, target)
    elif manifest.has_skill(target):
        stype = manifest.get_skill_type(target)
        if stype == "git-repo":
            _pull_git_skill(manifest, target)
        elif stype == "repo-synced":
            repo = manifest.get_skill(target).get("repo", "")
            if repo:
                _pull_repo(ctx, manifest, repo)
            else:
                output.error(f"Skill '{target}' has no upstream repo")
        else:
            output.error(f"Skill '{target}' has no upstream repo")
    else:
        output.error(f"'{target}' not found as repo or skill")


def _pull_all(ctx, manifest: Manifest) -> None:
    for repo_key in manifest.get_repos():
        _pull_repo(ctx, manifest, repo_key)

    # Pull git-repo type skills
    for name in manifest.skill_names():
        if manifest.get_skill_type(name) != "git-repo":
            continue
        skill = manifest.get_skill(name)
        if skill.get("pinned"):
            output.warn(f"{name} [PINNED] — skipped")
            continue
        _pull_git_skill(manifest, name)


def _pull_repo(ctx, manifest: Manifest, repo_key: str) -> None:
    repo_info = manifest.get_repo(repo_key)
    if not repo_info:
        return
    url = repo_info["url"]
    branch = repo_info.get("branch", "main")
    repo_dir = ctx.repos_dir / manifest.repo_to_dir(repo_key)

    if not git_ops.is_git_repo(repo_dir):
        print(f"  Cloning {repo_key} from {url}...")
        git_ops.clone_sparse(url, repo_dir, branch)
    else:
        print(f"  Pulling {repo_key}... ", end="", flush=True)
        before, after = git_ops.pull(repo_dir, branch)
        if before != after:
            print(output._c(output.GREEN, f"updated") + f" ({before} \u2192 {after})")
        else:
            print("already up to date")

    # Sync to skill paths
    for sname, sdata in manifest.get_skills_for_repo(repo_key).items():
        if sdata.get("pinned"):
            output.warn(f"  {sname} [PINNED] — skipped")
            continue
        subdir = sdata.get("subdir", "")
        dest = manifest.get_skill_path(sname)
        if not dest:
            continue

        print(f"    Syncing {sname}... ", end="", flush=True)
        source = repo_dir / subdir
        if not source.is_dir():
            output.error(f"source {repo_key}/{subdir} not found")
            continue
        sync_directory(source, dest)
        new_commit = git_ops.get_head(repo_dir)
        manifest.update_skill(sname, synced_commit=new_commit)
        print(output._c(output.GREEN, "done"))


def _pull_git_skill(manifest: Manifest, name: str) -> None:
    skill_path = manifest.get_skill_path(name)
    if not skill_path or not git_ops.is_git_repo(skill_path):
        return

    print(f"  Pulling {name} (git-repo)... ", end="", flush=True)
    before, after = git_ops.pull_inplace(skill_path)
    if before != after:
        print(output._c(output.GREEN, "updated") + f" ({before} \u2192 {after})")
    else:
        print("already up to date")
