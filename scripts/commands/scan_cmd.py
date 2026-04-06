"""Scan: discover unmanaged skills and report findings."""

from pathlib import Path

from scripts import output, git_ops
from scripts.manifest import Manifest
from scripts.scanner import (
    detect_clawhub,
    detect_skill_nature,
    find_in_repos,
    find_skill_in_targets,
)

def _ensure_initialized(ctx, manifest: Manifest) -> None:
    """Auto-detect and add target directories if none configured."""
    ctx.repos_dir.mkdir(parents=True, exist_ok=True)

    if not manifest.data.get("targets"):
        print(output._c(output.BLUE, "[Setup] Detecting agent directories..."))
        candidates = [
            (Path.home() / ".claude" / "skills", "claude", "Claude Code"),
            (Path.home() / ".openclaw" / "workspace" / "skills", "openclaw", "OpenClaw"),
        ]
        for dpath, dname, dlabel in candidates:
            if dpath.is_dir():
                manifest_path = manifest.to_manifest_path(dpath)
                manifest.add_target(dname, manifest_path)
                output.success(f"Auto-added target: {dname} → {dpath}")
        if not manifest.data.get("targets"):
            output.warn("No agent directories detected. Use add-target later.")
        print()


def _classify_skill(name, entry, actual_dir, ctx, manifest):
    """Classify a single unmanaged skill. Returns (kind, detail_dict)."""
    mpath = manifest.to_manifest_path(entry)

    # Git repo?
    if actual_dir.is_dir() and git_ops.is_git_repo(actual_dir):
        remote_url = git_ops.get_remote_url(actual_dir) or ""
        return "git-repo", {"remote_url": remote_url, "mpath": mpath, "actual_dir": actual_dir}

    # Symlink into a git repo?
    if entry.is_symlink() and actual_dir.is_dir():
        git_root = git_ops.get_git_root(actual_dir)
        if git_root:
            remote_url = git_ops.get_remote_url(git_root) or ""
            return "git-repo", {"remote_url": remote_url, "mpath": mpath, "actual_dir": actual_dir}

    # ClawHub?
    if actual_dir.is_dir():
        clawhub = detect_clawhub(actual_dir)
        if clawhub:
            return "clawhub", {"origin": clawhub, "mpath": mpath}

    # Repo match?
    match = find_in_repos(name, ctx.repos_dir, manifest)
    if match:
        return "repo-match", {"repo_key": match[0], "subdir": match[1], "mpath": mpath}

    # Heuristics
    nature = detect_skill_nature(actual_dir) if actual_dir.is_dir() else None
    if nature and nature.kind == "private":
        return "private", {"detail": nature.detail, "mpath": mpath}
    elif nature and nature.kind == "has-source-url":
        return "has-source-url", {"detail": nature.detail, "mpath": mpath}

    return "unknown", {"mpath": mpath}


def _register_skill(name, kind, detail, manifest):
    """Register a single skill based on its classification."""
    mpath = detail["mpath"]

    if kind == "git-repo":
        actual_mpath = manifest.to_manifest_path(detail["actual_dir"])
        data = {"path": actual_mpath, "type": "git-repo", "pinned": False}
        if detail.get("remote_url"):
            data["repo_url"] = detail["remote_url"]
        manifest.add_skill(name, data)

    elif kind == "clawhub":
        origin = detail["origin"]
        manifest.add_skill(name, {
            "path": mpath,
            "type": "clawhub",
            "clawhub_slug": origin.get("slug", name),
            "clawhub_version": origin.get("installedVersion", "?"),
            "clawhub_registry": origin.get("registry", "https://clawhub.ai"),
            "pinned": False,
        })

    elif kind == "repo-match":
        manifest.add_skill(name, {
            "path": mpath,
            "repo": detail["repo_key"],
            "subdir": detail["subdir"],
            "pinned": False,
        })

    elif kind == "private":
        manifest.add_skill(name, {"path": mpath, "repo": None, "note": f"Private: {detail['detail']}"})

    elif kind == "has-source-url":
        manifest.add_skill(name, {"path": mpath, "repo": None, "note": f"Source: {detail['detail']}"})

    else:  # unknown
        manifest.add_skill(name, {"path": mpath, "repo": None})


def _format_kind(kind, detail):
    """Format classification for display."""
    if kind == "git-repo":
        url = detail.get("remote_url", "")
        return f"git-repo{f': {url}' if url else ''}"
    elif kind == "clawhub":
        origin = detail["origin"]
        return f"clawhub: {origin.get('slug', '?')}@{origin.get('installedVersion', '?')}"
    elif kind == "repo-match":
        return f"found in {detail['repo_key']}/{detail['subdir']}"
    elif kind == "private":
        return f"private ({detail['detail']})"
    elif kind == "has-source-url":
        return f"source: {detail['detail']}"
    return "unknown origin"


def run(ctx, manifest: Manifest, args) -> None:
    auto_yes = getattr(args, "yes", False)

    output.header("Scan & Discover")
    print()

    _ensure_initialized(ctx, manifest)
    targets = manifest.get_targets()

    # --- Scan and classify ---
    print(output._c(output.BLUE, "[Scanning]"))

    findings: list[tuple[str, str, dict]] = []  # (name, kind, detail)
    scanned: set[str] = set()

    for _, tpath in targets.items():
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
                    output.success(f"✓ {name} — fixed missing path")
                continue

            actual_dir = entry.resolve() if entry.is_symlink() else entry
            kind, detail = _classify_skill(name, entry, actual_dir, ctx, manifest)
            findings.append((name, kind, detail))

    # --- Report findings ---
    if not findings:
        print("  All skills are managed.")
    else:
        print(f"  Found {len(findings)} unmanaged skill(s):")
        print()
        for name, kind, detail in findings:
            color = output.GREEN if kind in ("clawhub", "repo-match") else \
                    output.BLUE if kind == "git-repo" else \
                    output.YELLOW if kind == "private" else output.RED
            print(f"  {output._c(color, name)} — {_format_kind(kind, detail)}")

    # --- Auto-register if -y ---
    registered = 0
    if auto_yes and findings:
        print()
        print(output._c(output.BLUE, "[Auto-registering]"))
        for name, kind, detail in findings:
            _register_skill(name, kind, detail, manifest)
            output.success(f"✓ {name} ({kind})")
            registered += 1

    # --- Available in repos but not installed ---
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
        print()
        print(output._c(output.GREEN, "[Available in Repos — Not Installed]"))
        for sname, rname, subdir in available_in_repos:
            print(f"  {output._c(output.GREEN, sname)} — {rname}/{subdir}")

    # --- Summary ---
    print()
    output.header("Scan Complete")
    if registered:
        print(f"  Registered: {registered}")
    if findings and not auto_yes:
        print(f"  Unmanaged: {len(findings)} (use 'register <name>' to register, or 'scan -y' to register all)")
    print(f"  Total managed: {len(manifest.get_skills())}")
    if available_in_repos:
        print(f"  Available to install: {len(available_in_repos)} (use 'install <url>' to install)")
    print()
