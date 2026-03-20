"""Scan and recommend unmanaged skills."""

from scripts import output, git_ops
from scripts.manifest import Manifest
from scripts.scanner import (
    detect_skill_nature,
    collect_skills_from_targets,
    find_in_repos,
)


def run(ctx, manifest: Manifest, args) -> None:
    output.header("Scanning for recommendations")
    print()

    targets = manifest.get_targets()
    private_skills = []
    source_url_skills = []
    repo_match_skills = []
    unknown_skills = []
    git_repo_skills = []

    # Part 1: Scan unmanaged skills
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
                continue

            # Resolve actual dir
            actual_dir = entry.resolve() if entry.is_symlink() else entry

            # Check if it's a git repo
            if actual_dir.is_dir() and git_ops.is_git_repo(actual_dir):
                remote_url = git_ops.get_remote_url(actual_dir) or ""
                git_repo_skills.append((name, str(actual_dir), remote_url))
                continue

            # Check if symlink target is inside a git repo
            if entry.is_symlink() and actual_dir.is_dir():
                git_root = git_ops.get_git_root(actual_dir)
                if git_root:
                    remote_url = git_ops.get_remote_url(git_root) or ""
                    rel = actual_dir.relative_to(git_root)
                    git_repo_skills.append((name, str(actual_dir), f"{remote_url} (subdir: {rel})"))
                    continue

            # Search in cloned repos
            match = find_in_repos(name, ctx.repos_dir, manifest)
            if match:
                repo_match_skills.append((name, match[0], match[1], str(entry)))
                continue

            # Heuristics
            if actual_dir.is_dir():
                nature = detect_skill_nature(actual_dir)
            else:
                from scripts.scanner import SkillNature
                nature = SkillNature("clean")

            if nature.kind == "private":
                private_skills.append((name, nature.detail, str(entry)))
            elif nature.kind == "has-source-url":
                source_url_skills.append((name, nature.detail))
            else:
                unknown_skills.append((name, str(entry)))

    # Part 2: Available in repos but not installed
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
                # Check if already tracked by subdir
                already = any(
                    s.get("subdir") == skill_subdir
                    for s in manifest.get_skills_for_repo(repo_key).values()
                )
                if not already:
                    available_in_repos.append((skill_name, repo_key, skill_subdir))

    # Output
    total = 0

    if private_skills:
        print(output._c(output.YELLOW, "[Private/Infrastructure Skills]"))
        for sname, detail, spath in private_skills:
            print(f"  {output._c(output.YELLOW, sname)} — {detail}")
            print(f"    {output._c(output.BLUE, f'→ python3 scripts/main.py add-local {sname}')}")
        print(f"  {output._c(output.RED, 'Warning: contain credentials. Do NOT push to public repos.')}")
        print()
        total += len(private_skills)

    if git_repo_skills:
        print(output._c(output.BLUE, "[Git Repo Skills]"))
        for sname, spath, remote in git_repo_skills:
            print(f"  {output._c(output.BLUE, sname)} at {spath}")
            if remote:
                print(f"    Remote: {remote}")
            print(f"    {output._c(output.BLUE, f'→ python3 scripts/main.py add-git {sname} {spath}')}")
        print()
        total += len(git_repo_skills)

    if source_url_skills:
        print(output._c(output.BLUE, "[Skills with Source URL]"))
        for sname, url in source_url_skills:
            print(f"  {output._c(output.BLUE, sname)} — {url}")
        print()
        total += len(source_url_skills)

    if repo_match_skills:
        print(output._c(output.GREEN, "[Found in Cloned Repos]"))
        for sname, rname, subdir, spath in repo_match_skills:
            print(f"  {output._c(output.GREEN, sname)} — {rname}/{subdir}")
            print(f"    {output._c(output.BLUE, f'→ python3 scripts/main.py add-skill {sname} {rname} {subdir}')}")
        print()
        total += len(repo_match_skills)

    if unknown_skills:
        print(output._c(output.RED, "[Unknown Origin]"))
        for sname, spath in unknown_skills:
            print(f"  {output._c(output.RED, sname)} at {spath}")
            print(f"    {output._c(output.BLUE, f'→ python3 scripts/main.py add-local {sname}')}")
        print()
        total += len(unknown_skills)

    if available_in_repos:
        print(output._c(output.GREEN, "[Available in Cloned Repos — Not Installed]"))
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
                print(f"    {sname}  {output._c(output.BLUE, f'→ python3 scripts/main.py add-skill {sname} {rname} {subdir}')}")
        if count > 20:
            print(f"    ... and {count - 20} more")
        print()
        total += count

    if total == 0:
        print("All skills are managed. Nothing to recommend.")
    else:
        print(f"Total: {output._c(output.YELLOW, f'{total} recommendation(s)')}")
