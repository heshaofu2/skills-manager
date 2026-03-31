"""Scan: auto-initialize environment and discover unmanaged skills."""

from pathlib import Path

from scripts import output, git_ops
from scripts.manifest import Manifest
from scripts.scanner import (
    detect_skill_nature,
    collect_skills_from_targets,
    find_in_repos,
)


def _ensure_initialized(ctx, manifest: Manifest) -> None:
    """Ensure directory structure and targets are set up (absorbed from init)."""
    ctx.repos_dir.mkdir(parents=True, exist_ok=True)

    targets = manifest.get_targets()
    if not manifest.data.get("targets"):
        print(output._c(output.BLUE, "[Setup] Detecting agent directories..."))
        candidates = [
            (Path.home() / ".claude" / "skills", "claude", "Claude Code"),
            (Path.home() / ".openclaw" / "skills", "openclaw", "OpenClaw"),
        ]
        detected = False
        for dpath, dname, dlabel in candidates:
            if dpath.is_dir():
                answer = input(f"  Found {dpath} ({dlabel}). Add as target? [Y/n] ").strip()
                if not answer.lower().startswith('n'):
                    manifest_path = manifest.to_manifest_path(dpath)
                    manifest.add_target(dname, manifest_path)
                    output.success(f"Added target: {dname}")
                    detected = True
        if not detected:
            output.warn("No agent directories detected. Use add-target later.")
        print()


def run(ctx, manifest: Manifest, args) -> None:
    output.header("Scan & Discover")
    print()

    # Auto-initialize if needed
    _ensure_initialized(ctx, manifest)

    targets = manifest.get_targets()

    # --- Part 1: Register unmanaged skills interactively ---
    print(output._c(output.BLUE, "[Scanning existing skills]"))

    registered = 0
    scanned: set[str] = set()

    for tname, tpath in targets.items():
        if not tpath.is_dir():
            continue
        for entry in sorted(tpath.iterdir()):
            name = entry.name
            if name.startswith('.') or name == '.DS_Store':
                continue
            if name in scanned:
                continue
            scanned.add(name)

            if manifest.has_skill(name):
                # Fix missing path
                skill = manifest.get_skill(name)
                if not skill.get("path"):
                    mpath = manifest.to_manifest_path(entry)
                    manifest.update_skill(name, path=mpath)
                    output.success(f"✓ {name} — added path")
                    registered += 1
                continue

            actual_dir = entry.resolve() if entry.is_symlink() else entry
            mpath = manifest.to_manifest_path(entry)

            # Git repo?
            if actual_dir.is_dir() and git_ops.is_git_repo(actual_dir):
                remote_url = git_ops.get_remote_url(actual_dir) or ""
                label = f"git-repo{f': {remote_url}' if remote_url else ''}"
                answer = input(f"  {output._c(output.BLUE, name)} ({label}) — register? [Y/n] ").strip()
                if not answer.lower().startswith('n'):
                    actual_mpath = manifest.to_manifest_path(actual_dir)
                    data = {"path": actual_mpath, "type": "git-repo", "pinned": False}
                    if remote_url:
                        data["repo_url"] = remote_url
                    manifest.add_skill(name, data)
                    output.success("✓ Registered as git-repo")
                    registered += 1
                continue

            # Symlink into a git repo?
            if entry.is_symlink() and actual_dir.is_dir():
                git_root = git_ops.get_git_root(actual_dir)
                if git_root:
                    remote_url = git_ops.get_remote_url(git_root) or ""
                    rel = actual_dir.relative_to(git_root)
                    label = f"git-repo subdir: {rel}"
                    if remote_url:
                        label += f" ({remote_url})"
                    answer = input(f"  {output._c(output.BLUE, name)} ({label}) — register? [Y/n] ").strip()
                    if not answer.lower().startswith('n'):
                        actual_mpath = manifest.to_manifest_path(actual_dir)
                        data = {"path": actual_mpath, "type": "git-repo", "pinned": False}
                        if remote_url:
                            data["repo_url"] = remote_url
                        manifest.add_skill(name, data)
                        output.success("✓ Registered as git-repo")
                        registered += 1
                    continue

            # Try repo match
            match = find_in_repos(name, ctx.repos_dir, manifest)
            if match:
                repo_key, subdir = match
                answer = input(f"  {output._c(output.GREEN, name)} → found in {repo_key} — register? [Y/n] ").strip()
                if not answer.lower().startswith('n'):
                    manifest.add_skill(name, {"path": mpath, "repo": repo_key, "subdir": subdir, "pinned": False})
                    output.success("✓ Registered")
                    registered += 1
                continue

            # Heuristics
            nature = detect_skill_nature(actual_dir) if actual_dir.is_dir() else None

            if nature and nature.kind == "private":
                answer = input(f"  {output._c(output.YELLOW, name)} ({nature.kind}:{nature.detail}) — register as local? [Y/n] ").strip()
                if not answer.lower().startswith('n'):
                    manifest.add_skill(name, {"path": mpath, "repo": None, "note": f"Private: {nature.detail}"})
                    output.success("✓ Registered as local")
                    registered += 1

            elif nature and nature.kind == "has-source-url":
                print(f"  {output._c(output.BLUE, name)} — found URL: {nature.detail}")
                print("    [1] Register as local  [2] Skip")
                choice = input("    Choice [1/2]: ").strip()
                if choice == "1":
                    manifest.add_skill(name, {"path": mpath, "repo": None, "note": f"Source: {nature.detail}"})
                    output.success("✓ Registered as local")
                    registered += 1

            else:
                print(f"  {output._c(output.RED, name)} — unknown origin")
                print("    [1] Register as local  [2] Skip")
                choice = input("    Choice [1/2]: ").strip()
                if choice == "1":
                    manifest.add_skill(name, {"path": mpath, "repo": None})
                    output.success("✓ Registered as local")
                    registered += 1

    print()

    # --- Part 2: Available in repos but not installed ---
    available_in_repos = []
    if ctx.repos_dir.is_dir():
        for repo_dir in sorted(ctx.repos_dir.iterdir()):
            if not repo_dir.is_dir():
                continue
            repo_key = manifest.dir_to_repo(repo_dir.name)
            skills_dir = repo_dir / "skills"
            if not skills_dir.is_dir():
                continue
            for skill_md in skills_dir.rglob("SKILL.md"):
                skill_subdir = str(skill_md.relative_to(repo_dir).parent)
                skill_name = skill_md.parent.name
                if manifest.has_skill(skill_name):
                    continue
                already = any(
                    s.get("subdir") == skill_subdir
                    for s in manifest.get_skills_for_repo(repo_key).values()
                )
                if not already:
                    available_in_repos.append((skill_name, repo_key, skill_subdir))

    if available_in_repos:
        print(output._c(output.GREEN, "[Available in Repos — Not Installed]"))
        prev_repo = ""
        count = 0
        for sname, rname, subdir in available_in_repos:
            if rname != prev_repo:
                if prev_repo:
                    print()
                print(f"  {output._c(output.GREEN, rname)}:")
                prev_repo = rname
            count += 1
            if count <= 20:
                print(f"    {sname}  {output._c(output.BLUE, f'→ skills-manager add-skill {sname} {rname} {subdir}')}")
        if count > 20:
            print(f"    ... and {count - 20} more")
        print()

    # --- Summary ---
    output.header("Scan Complete")
    print(f"  Registered: {registered}")
    print(f"  Total skills: {len(manifest.get_skills())}")
    if available_in_repos:
        print(f"  Available to install: {len(available_in_repos)}")
    print()
