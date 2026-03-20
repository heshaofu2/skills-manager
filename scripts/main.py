#!/usr/bin/env python3
"""Skills Manager CLI — manage agent skills from GitHub repos."""

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

# Ensure the parent directory is in sys.path so `scripts` is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scripts.manifest import Manifest


@dataclass
class Context:
    manager_dir: Path
    manifest_path: Path
    repos_dir: Path


def main() -> None:
    ctx = Context(
        manager_dir=Path.home() / ".agents" / "skills-manager",
        manifest_path=Path.home() / ".agents" / "skills-manager" / "manifest.json",
        repos_dir=Path.home() / ".agents" / "skills-manager" / "repos",
    )

    parser = argparse.ArgumentParser(prog="skills-manager", description="Manage agent skills from GitHub repos")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("init", help="Initialize: scan and register existing skills")
    sub.add_parser("list", help="List all skills and their status")
    sub.add_parser("check", help="Check for available updates")

    p_pull = sub.add_parser("pull", help="Pull updates and sync")
    p_pull.add_argument("target", nargs="?", default="", help="Repo or skill name")

    p_add_repo = sub.add_parser("add-repo", help="Register a new repo source")
    p_add_repo.add_argument("name", help="Local name for the repo (e.g. anthropics/skills)")
    p_add_repo.add_argument("url", help="Git URL")
    p_add_repo.add_argument("branch", nargs="?", default="main", help="Branch (default: main)")

    p_add_skill = sub.add_parser("add-skill", help="Install a skill from a repo")
    p_add_skill.add_argument("name", help="Skill name")
    p_add_skill.add_argument("repo", help="Repo name")
    p_add_skill.add_argument("subdir", help="Subdirectory in repo")

    p_add_git = sub.add_parser("add-git", help="Register a git-repo skill")
    p_add_git.add_argument("name", help="Skill name")
    p_add_git.add_argument("path", help="Path to git repo")
    p_add_git.add_argument("repo_url", nargs="?", default=None, help="Remote URL")

    p_add_local = sub.add_parser("add-local", help="Register a local skill")
    p_add_local.add_argument("name", help="Skill name")
    p_add_local.add_argument("note", nargs="?", default="", help="Description note")

    p_remove = sub.add_parser("remove", help="Unregister a skill")
    p_remove.add_argument("name", help="Skill name")

    p_add_target = sub.add_parser("add-target", help="Add a target directory")
    p_add_target.add_argument("name", help="Target name")
    p_add_target.add_argument("path", help="Directory path")

    p_remove_target = sub.add_parser("remove-target", help="Remove a target directory")
    p_remove_target.add_argument("name", help="Target name")

    sub.add_parser("scan", help="Scan and recommend unmanaged skills")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return

    manifest = Manifest(ctx.manifest_path)

    if args.command == "init":
        from scripts.commands.init_cmd import run
        run(ctx, manifest, args)
    elif args.command == "list":
        from scripts.commands.list_cmd import run
        run(ctx, manifest, args)
    elif args.command == "check":
        from scripts.commands.check_cmd import run
        run(ctx, manifest, args)
    elif args.command == "pull":
        from scripts.commands.pull_cmd import run
        run(ctx, manifest, args)
    elif args.command == "add-repo":
        from scripts.commands.add_cmd import run_add_repo
        run_add_repo(ctx, manifest, args)
    elif args.command == "add-skill":
        from scripts.commands.add_cmd import run_add_skill
        run_add_skill(ctx, manifest, args)
    elif args.command == "add-git":
        from scripts.commands.add_cmd import run_add_git
        run_add_git(ctx, manifest, args)
    elif args.command == "add-local":
        from scripts.commands.add_cmd import run_add_local
        run_add_local(ctx, manifest, args)
    elif args.command == "remove":
        from scripts.commands.remove_cmd import run
        run(ctx, manifest, args)
    elif args.command == "add-target":
        from scripts.commands.target_cmd import run_add
        run_add(ctx, manifest, args)
    elif args.command == "remove-target":
        from scripts.commands.target_cmd import run_remove
        run_remove(ctx, manifest, args)
    elif args.command == "scan":
        from scripts.commands.scan_cmd import run
        run(ctx, manifest, args)


if __name__ == "__main__":
    main()
