"""Install a skill from a GitHub URL."""

import re
from pathlib import Path
from typing import Optional

from scripts import output, git_ops
from scripts.manifest import Manifest
from scripts.sync import ensure_symlink


def parse_github_url(url: str) -> Optional[dict]:
    """Parse a GitHub URL into repo, branch, and subdir.

    Supported formats:
      https://github.com/owner/repo/tree/branch/path/to/skill
      https://github.com/owner/repo
      git@github.com:owner/repo.git
    """
    # HTTPS with tree path: github.com/owner/repo/tree/branch/subdir
    m = re.match(
        r'https?://github\.com/([\w._-]+/[\w._-]+)/tree/([^/]+)(?:/(.+))?',
        url,
    )
    if m:
        repo = m.group(1)
        branch = m.group(2)
        subdir = m.group(3) or "."
        return {"repo": repo, "branch": branch, "subdir": subdir}

    # HTTPS bare repo: github.com/owner/repo
    m = re.match(
        r'https?://github\.com/([\w._-]+/[\w._-]+?)(?:\.git)?/?$',
        url,
    )
    if m:
        return {"repo": m.group(1), "branch": "main", "subdir": "."}

    # SSH: git@github.com:owner/repo.git
    m = re.match(
        r'git@github\.com:([\w._-]+/[\w._-]+?)(?:\.git)?$',
        url,
    )
    if m:
        return {"repo": m.group(1), "branch": "main", "subdir": "."}

    return None


def _derive_skill_name(parsed: dict) -> str:
    """Derive skill name from parsed URL info."""
    subdir = parsed["subdir"]
    if subdir == ".":
        # Whole repo is the skill — use repo name
        return parsed["repo"].split("/")[-1]
    else:
        # Subdir — use last path component
        return subdir.rstrip("/").split("/")[-1]


def run(ctx, manifest: Manifest, args) -> None:
    url = args.url
    name_override = getattr(args, "name", None)

    parsed = parse_github_url(url)
    if not parsed:
        output.error(f"Cannot parse URL: {url}")
        print("  Supported: https://github.com/owner/repo[/tree/branch/subdir]")
        return

    repo_key = parsed["repo"]
    branch = parsed["branch"]
    subdir = parsed["subdir"]
    skill_name = name_override or _derive_skill_name(parsed)

    output.header(f"Installing {skill_name}")
    print(f"  Repo:   {repo_key}")
    print(f"  Branch: {branch}")
    print(f"  Subdir: {subdir}")
    print()

    # Check if skill already registered
    if manifest.has_skill(skill_name):
        output.warn(f"Skill '{skill_name}' already registered. Use 'pull' to update.")
        return

    # Step 1: Ensure repo is registered and cloned
    repo_dir = ctx.repos_dir / manifest.repo_to_dir(repo_key)
    git_url = f"https://github.com/{repo_key}.git"

    if not manifest.has_repo(repo_key):
        print(f"  Registering repo {repo_key}...")
        manifest.add_repo(repo_key, git_url, branch)

    if not git_ops.is_git_repo(repo_dir):
        print(f"  Cloning {repo_key} (sparse)...")
        git_ops.clone_sparse(git_url, repo_dir, branch)
    else:
        print(f"  Repo already cloned, fetching latest...")
        git_ops.fetch(repo_dir, branch)
        git_ops.pull(repo_dir, branch)

    # Step 2: Sparse checkout the subdir
    if subdir != ".":
        print(f"  Adding sparse checkout: {subdir}")
        git_ops.sparse_checkout_add(repo_dir, subdir)

    source = repo_dir / subdir if subdir != "." else repo_dir
    if not source.is_dir():
        output.error(f"Directory not found after checkout: {subdir}")
        return

    # Verify it looks like a skill
    if not (source / "SKILL.md").is_file():
        output.warn(f"No SKILL.md found in {subdir}. Installing anyway.")

    # Step 3: Link to target directory (symlink for subdirs, copy for whole-repo)
    targets = manifest.get_targets()
    first_target = next((p for p in targets.values() if p.is_dir()), None)
    if not first_target:
        output.error("No target directory available. Use add-target first.")
        return

    skill_path = first_target / skill_name
    print(f"  Linking to {skill_path}...")
    ensure_symlink(source, skill_path)

    # Step 4: Register in manifest
    synced_commit = git_ops.get_head(repo_dir)
    manifest.add_skill(skill_name, {
        "path": manifest.to_manifest_path(skill_path),
        "repo": repo_key,
        "subdir": subdir,
        "synced_commit": synced_commit,
        "pinned": False,
    })

    print()
    output.success(f"✓ {skill_name} installed successfully")
