"""Git subprocess wrappers."""

import subprocess
from pathlib import Path
from typing import Optional


class GitError(Exception):
    pass


def _run(*args: str, cwd: Path | None = None, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        raise GitError(result.stderr.strip() or f"git {args[0]} failed")
    return result.stdout.strip()


def clone_sparse(url: str, dest: Path, branch: str = "main") -> None:
    subprocess.run(
        ["git", "clone", "--filter=blob:none", "--sparse", "--branch", branch, url, str(dest)],
        check=True,
    )


def fetch(repo_dir: Path, branch: str = "main") -> None:
    _run("fetch", "origin", branch, "--quiet", cwd=repo_dir, check=False)


def pull(repo_dir: Path, branch: str = "main") -> tuple[str, str]:
    before = get_head_short(repo_dir)
    _run("pull", "origin", branch, "--quiet", cwd=repo_dir, check=False)
    after = get_head_short(repo_dir)
    return before, after


def pull_inplace(repo_dir: Path) -> tuple[str, str]:
    before = get_head_short(repo_dir)
    _run("pull", "--quiet", cwd=repo_dir, check=False)
    after = get_head_short(repo_dir)
    return before, after


def get_head(repo_dir: Path) -> str:
    return _run("rev-parse", "HEAD", cwd=repo_dir, check=False)


def get_head_short(repo_dir: Path) -> str:
    return _run("rev-parse", "--short", "HEAD", cwd=repo_dir, check=False)


def get_remote_url(repo_dir: Path) -> Optional[str]:
    try:
        return _run("remote", "get-url", "origin", cwd=repo_dir)
    except GitError:
        return None


def get_current_branch(repo_dir: Path) -> str:
    try:
        return _run("rev-parse", "--abbrev-ref", "HEAD", cwd=repo_dir)
    except GitError:
        return "main"


def rev_list_count(repo_dir: Path, from_ref: str, to_ref: str) -> int:
    out = _run("rev-list", f"{from_ref}..{to_ref}", "--count", cwd=repo_dir, check=False)
    try:
        return int(out)
    except ValueError:
        return 0


def has_diff(repo_dir: Path, from_ref: str, to_ref: str, path: str) -> bool:
    result = subprocess.run(
        ["git", "diff", "--quiet", from_ref, to_ref, "--", f"{path}/"],
        cwd=repo_dir,
        capture_output=True,
    )
    return result.returncode != 0


def sparse_checkout_set(repo_dir: Path, paths: list[str]) -> None:
    if paths:
        _run("sparse-checkout", "set", *paths, cwd=repo_dir, check=False)


def sparse_checkout_add(repo_dir: Path, path: str) -> None:
    _run("sparse-checkout", "add", path, cwd=repo_dir, check=False)


def is_git_repo(path: Path) -> bool:
    return (path / ".git").is_dir()


def get_git_root(path: Path) -> Optional[Path]:
    try:
        root = _run("rev-parse", "--show-toplevel", cwd=path)
        return Path(root) if root else None
    except GitError:
        return None
