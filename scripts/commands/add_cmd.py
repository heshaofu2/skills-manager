"""Add repo, skill, git-repo, or local skill."""

from scripts import output, git_ops
from scripts.manifest import Manifest
from scripts.sync import sync_directory
from scripts.scanner import find_skill_in_targets


def run_add_repo(ctx, manifest: Manifest, args) -> None:
    name = args.name
    url = args.url
    branch = getattr(args, "branch", "main") or "main"

    if manifest.has_repo(name):
        output.warn(f"Repo '{name}' already exists in manifest")
        return

    manifest.add_repo(name, url, branch)
    dest = ctx.repos_dir / manifest.repo_to_dir(name)

    print(f"Cloning {name} from {url} (sparse)...")
    git_ops.clone_sparse(url, dest, branch)
    output.success(f"Done. Now use 'add-skill' to register skills from this repo.")


def run_add_skill(ctx, manifest: Manifest, args) -> None:
    name = args.name
    repo = args.repo
    subdir = args.subdir

    if not manifest.has_repo(repo):
        output.error(f"Repo '{repo}' not found. Add it first with add-repo.")
        return

    # Determine skill path
    targets = manifest.get_targets()
    found = find_skill_in_targets(name, targets)
    if found:
        tname, skill_path = found
        print(f"  Found existing at: {skill_path}")
        output.warn("Warning: local content will be overwritten by upstream.")
    else:
        first_target = next((p for p in targets.values() if p.is_dir()), None)
        if not first_target:
            output.error("No target directory available. Add one with add-target.")
            return
        skill_path = first_target / name
        print(f"  Installing to: {skill_path}")

    # Update sparse checkout
    repo_dir = ctx.repos_dir / manifest.repo_to_dir(repo)
    git_ops.sparse_checkout_add(repo_dir, subdir)

    source = repo_dir / subdir
    if not source.is_dir():
        output.error(f"Directory '{subdir}' not found in repo '{repo}' after sparse checkout")
        return

    sync_directory(source, skill_path)

    synced_commit = git_ops.get_head(repo_dir)
    manifest.add_skill(name, {
        "path": manifest.to_manifest_path(skill_path),
        "repo": repo,
        "subdir": subdir,
        "synced_commit": synced_commit,
        "pinned": False,
    })
    output.success(f"Skill '{name}' registered at {skill_path}")


def run_add_git(ctx, manifest: Manifest, args) -> None:
    name = args.name
    path = args.path
    repo_url = getattr(args, "repo_url", None) or None

    expanded = manifest.expand_path(path)
    if not git_ops.is_git_repo(expanded):
        output.error(f"{path} is not a git repository")
        return

    if not repo_url:
        repo_url = git_ops.get_remote_url(expanded) or ""

    data = {
        "path": manifest.to_manifest_path(expanded),
        "type": "git-repo",
        "pinned": False,
    }
    if repo_url:
        data["repo_url"] = repo_url

    manifest.add_skill(name, data)
    output.success(f"Skill '{name}' registered as git-repo at {path}")


def run_add_local(ctx, manifest: Manifest, args) -> None:
    name = args.name
    note = getattr(args, "note", "") or ""

    if manifest.has_skill(name):
        output.warn(f"Skill '{name}' already exists in manifest")
        return

    targets = manifest.get_targets()
    found = find_skill_in_targets(name, targets)
    if not found:
        output.error(f"Skill '{name}' not found in any target directory")
        return

    _, skill_path = found
    data = {
        "path": manifest.to_manifest_path(skill_path),
        "repo": None,
    }
    if note:
        data["note"] = note

    manifest.add_skill(name, data)
    output.success(f"Skill '{name}' registered as local ({skill_path})")
