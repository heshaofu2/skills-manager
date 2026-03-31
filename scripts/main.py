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

    p_status = sub.add_parser("status", help="Show all skills and their status")
    p_status.add_argument("-r", "--remote", action="store_true", help="Also check remote for updates")

    p_scan = sub.add_parser("scan", help="Initialize environment and discover unmanaged skills")
    p_scan.add_argument("-y", "--yes", action="store_true", help="Auto-accept all prompts (non-interactive mode)")

    p_pull = sub.add_parser("pull", help="Pull updates and sync")
    p_pull.add_argument("target", nargs="?", default="", help="Repo or skill name")

    p_install = sub.add_parser("install", help="Install a skill from a GitHub URL")
    p_install.add_argument("url", help="GitHub URL (e.g. https://github.com/owner/repo/tree/main/skills/name)")
    p_install.add_argument("--name", help="Override skill name")

    p_register = sub.add_parser("register", help="Register an unmanaged skill by name")
    p_register.add_argument("name", help="Skill name")

    p_uninstall = sub.add_parser("uninstall", help="Uninstall a skill")
    p_uninstall.add_argument("name", help="Skill name")
    p_uninstall.add_argument("--keep-files", action="store_true", help="Only remove from manifest, keep files")

    p_add_repo = sub.add_parser("add-repo", help="Register a new repo source")
    p_add_repo.add_argument("name", help="Local name for the repo (e.g. anthropics/skills)")
    p_add_repo.add_argument("url", help="Git URL")
    p_add_repo.add_argument("branch", nargs="?", default="main", help="Branch (default: main)")

    p_add_target = sub.add_parser("add-target", help="Add a target directory")
    p_add_target.add_argument("name", help="Target name")
    p_add_target.add_argument("path", help="Directory path")

    p_remove_target = sub.add_parser("remove-target", help="Remove a target directory")
    p_remove_target.add_argument("name", help="Target name")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return

    manifest = Manifest(ctx.manifest_path)

    if args.command == "status":
        from scripts.commands.status_cmd import run
        run(ctx, manifest, args)
    elif args.command == "scan":
        from scripts.commands.scan_cmd import run
        run(ctx, manifest, args)
    elif args.command == "pull":
        from scripts.commands.pull_cmd import run
        run(ctx, manifest, args)
    elif args.command == "install":
        from scripts.commands.install_cmd import run
        run(ctx, manifest, args)
    elif args.command == "register":
        from scripts.commands.register_cmd import run
        run(ctx, manifest, args)
    elif args.command == "uninstall":
        from scripts.commands.uninstall_cmd import run
        run(ctx, manifest, args)
    elif args.command == "add-repo":
        from scripts.commands.add_cmd import run_add_repo
        run_add_repo(ctx, manifest, args)
    elif args.command == "add-target":
        from scripts.commands.target_cmd import run_add
        run_add(ctx, manifest, args)
    elif args.command == "remove-target":
        from scripts.commands.target_cmd import run_remove
        run_remove(ctx, manifest, args)


if __name__ == "__main__":
    main()
