"""Initialize: scan and register existing skills."""

from pathlib import Path

from scripts import output, git_ops
from scripts.manifest import Manifest
from scripts.scanner import detect_skill_nature, find_in_repos


def run(ctx, manifest: Manifest, args) -> None:
    output.header("Skills Manager Init")
    print()

    # Step 1: Directory structure
    print(output._c(output.BLUE, "[Step 1] Directory structure"))
    ctx.repos_dir.mkdir(parents=True, exist_ok=True)
    output.success(f"OK {ctx.manager_dir}")

    # Step 2: Manifest
    print(output._c(output.BLUE, "[Step 2] Manifest"))
    ver = manifest.data.get("version", "1.0")
    skill_count = len(manifest.get_skills())
    output.success(f"Exists manifest.json (v{ver}, {skill_count} skills)")

    # Step 3: Targets
    print(output._c(output.BLUE, "[Step 3] Targets"))
    targets = manifest.get_targets()
    if not manifest.data.get("targets"):
        detected = False
        candidates = [
            (Path.home() / ".claude" / "skills", "claude", "Claude Code"),
            (Path.home() / ".openclaw" / "skills", "openclaw", "OpenClaw"),
        ]
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
        targets = manifest.get_targets()
    else:
        output.success(f"OK {len(targets)} target(s)")
        for tname, tpath in targets.items():
            print(f"    {tname} \u2192 {tpath}")
    print()

    # Step 4: Scan existing skills
    print(output._c(output.BLUE, "[Step 4] Scanning existing skills"))

    total_actions = 0
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

            # Already registered
            if manifest.has_skill(name):
                skill = manifest.get_skill(name)
                if not skill.get("path"):
                    mpath = manifest.to_manifest_path(entry)
                    manifest.update_skill(name, path=mpath)
                    output.success(f"\u2713 {name} — added path")
                    total_actions += 1
                else:
                    output.success(f"\u2713 {name}")
                continue

            # Resolve actual dir
            actual_dir = entry.resolve() if entry.is_symlink() else entry
            mpath = manifest.to_manifest_path(entry)

            # Is it a git repo?
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
                    output.success("\u2713 Registered as git-repo")
                    total_actions += 1
                continue

            # Heuristics
            nature = detect_skill_nature(actual_dir) if actual_dir.is_dir() else None

            if nature and nature.kind == "private":
                answer = input(f"  {output._c(output.YELLOW, name)} ({nature.kind}:{nature.detail}) — register as local? [Y/n] ").strip()
                if not answer.lower().startswith('n'):
                    manifest.add_skill(name, {"path": mpath, "repo": None, "note": f"Private: {nature.detail}"})
                    output.success("\u2713 Registered as local")
                    total_actions += 1

            elif nature and nature.kind == "has-source-url":
                print(f"  {output._c(output.BLUE, name)} — found URL: {nature.detail}")
                print("    [1] Register as local for now")
                print("    [2] Skip")
                choice = input("    Choice [1/2]: ").strip()
                if choice == "1":
                    manifest.add_skill(name, {"path": mpath, "repo": None, "note": f"Source: {nature.detail}"})
                    output.success("\u2713 Registered as local")
                    total_actions += 1

            else:
                # Try repo match
                match = find_in_repos(name, ctx.repos_dir, manifest)
                if match:
                    repo_key, subdir = match
                    answer = input(f"  {output._c(output.GREEN, name)} \u2192 found in {repo_key} — register as repo-synced? [Y/n] ").strip()
                    if not answer.lower().startswith('n'):
                        manifest.add_skill(name, {"path": mpath, "repo": repo_key, "subdir": subdir, "pinned": False})
                        output.success("\u2713 Registered")
                        total_actions += 1
                else:
                    print(f"  {output._c(output.RED, name)} — unknown origin")
                    print("    [1] Register as local  [2] Skip")
                    choice = input("    Choice [1/2]: ").strip()
                    if choice == "1":
                        manifest.add_skill(name, {"path": mpath, "repo": None})
                        output.success("\u2713 Registered as local")
                        total_actions += 1

    print()
    output.header("Init Complete")
    print(f"  Actions: {total_actions}")
    print(f"  Skills in manifest: {len(manifest.get_skills())}")
    print()
    print(f"Next: {output._c(output.BLUE, 'python3 scripts/main.py list')} / check / scan")
