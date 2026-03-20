"""Skill discovery and classification."""

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class SkillNature:
    kind: str  # "private", "has-source-url", "clean"
    detail: str = ""


_SENSITIVE_PATTERNS = ("*.pem", ".env", "*.key", "credentials*")
_IP_RE = re.compile(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b')
_SSH_RE = re.compile(r'\.pem|\.ssh/|id_rsa|id_ed25519|ssh_key', re.IGNORECASE)
_CRED_RE = re.compile(r'password|token|secret|credential|api.key', re.IGNORECASE)
_GITHUB_RE = re.compile(r'github\.com/[\w._-]+/[\w._-]+')


def detect_skill_nature(skill_dir: Path) -> SkillNature:
    """Classify a skill directory using heuristics."""
    # Check for sensitive files
    for pattern in _SENSITIVE_PATTERNS:
        matches = list(skill_dir.rglob(pattern))
        # Limit depth to 2
        matches = [m for m in matches if len(m.relative_to(skill_dir).parts) <= 2]
        if matches:
            return SkillNature("private", f"sensitive-file:{matches[0].name}")

    # Check SKILL.md content
    skill_md = skill_dir / "SKILL.md"
    if skill_md.is_file():
        try:
            content = skill_md.read_text(errors='ignore')
        except OSError:
            return SkillNature("clean")

        # IP addresses
        ip_match = _IP_RE.search(content)
        if ip_match:
            return SkillNature("private", f"ip:{ip_match.group()}")

        # SSH key references
        if _SSH_RE.search(content):
            return SkillNature("private", "ssh-key")

        # Credentials
        if _CRED_RE.search(content):
            return SkillNature("private", "credentials")

        # GitHub URL
        gh_match = _GITHUB_RE.search(content)
        if gh_match:
            return SkillNature("has-source-url", f"https://{gh_match.group()}")

    return SkillNature("clean")


def collect_skills_from_targets(targets: dict[str, Path]) -> list[str]:
    """Collect deduplicated skill names from all target directories."""
    seen: set[str] = set()
    result: list[str] = []
    for tpath in targets.values():
        if not tpath.is_dir():
            continue
        for entry in sorted(tpath.iterdir()):
            name = entry.name
            if name.startswith('.') or name == '.DS_Store':
                continue
            if name not in seen:
                seen.add(name)
                result.append(name)
    return result


def find_skill_in_targets(name: str, targets: dict[str, Path]) -> Optional[tuple[str, Path]]:
    """Find the first target directory containing a skill. Returns (target_name, full_path)."""
    for tname, tpath in targets.items():
        spath = tpath / name
        if spath.exists() or spath.is_symlink():
            return tname, spath
    return None


def find_in_repos(name: str, repos_dir: Path, manifest) -> Optional[tuple[str, str]]:
    """Search cloned repos for a skill. Returns (repo_key, subdir)."""
    if not repos_dir.is_dir():
        return None
    for repo_dir in sorted(repos_dir.iterdir()):
        if not repo_dir.is_dir():
            continue
        repo_key = manifest.dir_to_repo(repo_dir.name)
        # Direct match: skills/<name>/SKILL.md
        if (repo_dir / "skills" / name / "SKILL.md").is_file():
            return repo_key, f"skills/{name}"
        # Nested match: skills/<author>/<name>/SKILL.md
        skills_dir = repo_dir / "skills"
        if skills_dir.is_dir():
            for author_dir in skills_dir.iterdir():
                if author_dir.is_dir() and (author_dir / name / "SKILL.md").is_file():
                    rel = (author_dir / name).relative_to(repo_dir)
                    return repo_key, str(rel)
    return None
