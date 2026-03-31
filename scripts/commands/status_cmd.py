"""Show skills status, optionally check remote for updates."""

from scripts import output, git_ops
from scripts.manifest import Manifest
from scripts.scanner import collect_skills_from_targets


def run(ctx, manifest: Manifest, args) -> None:
    remote = getattr(args, "remote", False)

    if remote:
        output.header("Skills Status (with remote check)")
    else:
        output.header("Skills Status")

    targets = manifest.get_targets()
    target_names = ", ".join(targets.keys())
    print(f"  Targets: {output._c(output.GREEN, target_names)}")
    print()

    # Collect all skill names (from manifest + targets)
    all_names = set(manifest.skill_names())
    all_names.update(collect_skills_from_targets(targets))

    # Pre-fetch repos if remote mode
    repo_remote_info: dict[str, dict] = {}
    if remote:
        repo_remote_info = _fetch_repos(ctx, manifest)

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
            _show_git_repo(ctx, manifest, name, skill, path, path_status, pin_marker, remote)

        elif stype == "repo-synced":
            _show_repo_synced(ctx, manifest, name, skill, path, path_status, pin_marker, remote, repo_remote_info)

        elif stype == "local":
            note = skill.get("note", "")
            print(f"  {output._c(output.YELLOW, name)} (local) {path} {note}")

    print()


def _fetch_repos(ctx, manifest: Manifest) -> dict[str, dict]:
    """Fetch all repos and return remote commit info."""
    info: dict[str, dict] = {}

    for repo_key, repo_data in manifest.get_repos().items():
        branch = repo_data.get("branch", "main")
        repo_dir = ctx.repos_dir / manifest.repo_to_dir(repo_key)

        if not git_ops.is_git_repo(repo_dir):
            info[repo_key] = {"error": "not cloned"}
            continue

        print(f"  Fetching {repo_key}... ", end="", flush=True)
        git_ops.fetch(repo_dir, branch)

        local_commit = git_ops.get_head(repo_dir)
        try:
            remote_commit = git_ops._run("rev-parse", f"origin/{branch}", cwd=repo_dir)
        except git_ops.GitError:
            remote_commit = local_commit

        behind = 0
        if local_commit != remote_commit:
            behind = git_ops.rev_list_count(repo_dir, "HEAD", f"origin/{branch}")

        info[repo_key] = {
            "local": local_commit,
            "remote": remote_commit,
            "behind": behind,
            "branch": branch,
        }
        if behind:
            print(output._c(output.YELLOW, f"{behind} new commit(s)"))
        else:
            print(output._c(output.GREEN, "up to date"))

    print()
    return info


def _show_git_repo(ctx, manifest, name, skill, path, path_status, pin_marker, remote):
    commit = ""
    expanded = manifest.expand_path(path) if path else None
    if expanded and git_ops.is_git_repo(expanded):
        commit = git_ops.get_head_short(expanded)

    update_info = ""
    if remote and expanded and git_ops.is_git_repo(expanded):
        branch = git_ops.get_current_branch(expanded)
        git_ops.fetch(expanded, branch)
        local = git_ops.get_head(expanded)
        try:
            remote_commit = git_ops._run("rev-parse", f"origin/{branch}", cwd=expanded)
        except git_ops.GitError:
            remote_commit = local
        if local != remote_commit:
            behind = git_ops.rev_list_count(expanded, "HEAD", f"origin/{branch}")
            if behind > 0:
                update_info = f" {output._c(output.YELLOW, f'← {behind} update(s)')}"

    print(f"  {output._c(output.GREEN, name)} (git-repo) [{commit}] {path}{path_status}{pin_marker}{update_info}")


def _show_repo_synced(ctx, manifest, name, skill, path, path_status, pin_marker, remote, repo_remote_info):
    repo = skill.get("repo", "")
    subdir = skill.get("subdir", "")
    commit = ""
    repo_dir = ctx.repos_dir / manifest.repo_to_dir(repo)
    if git_ops.is_git_repo(repo_dir):
        commit = git_ops.get_head_short(repo_dir)

    update_info = ""
    if remote and repo in repo_remote_info:
        ri = repo_remote_info[repo]
        if ri.get("behind", 0) > 0:
            synced = skill.get("synced_commit", ri["local"])
            branch = ri["branch"]
            if git_ops.has_diff(repo_dir, synced, f"origin/{branch}", subdir):
                update_info = f" {output._c(output.YELLOW, '← has updates')}"

    print(f"  {output._c(output.GREEN, name)} → {repo}/{subdir} [{commit}] {path}{path_status}{pin_marker}{update_info}")
