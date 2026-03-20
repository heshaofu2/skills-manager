"""Manifest read/write/query operations."""

import json
import os
import tempfile
from pathlib import Path
from typing import Optional


class Manifest:
    """Read, query, and write manifest.json atomically."""

    def __init__(self, path: Path):
        self._path = path
        self._data: dict = {}
        self.load()

    def load(self) -> None:
        if self._path.exists():
            self._data = json.loads(self._path.read_text())
        else:
            self._data = {"version": "2.0", "targets": {}, "repos": {}, "skills": {}}

    def save(self) -> None:
        fd, tmp = tempfile.mkstemp(dir=self._path.parent, suffix=".json")
        try:
            with os.fdopen(fd, 'w') as f:
                json.dump(self._data, f, indent=2, ensure_ascii=False)
                f.write('\n')
            os.replace(tmp, self._path)
        except Exception:
            os.unlink(tmp)
            raise

    @property
    def data(self) -> dict:
        return self._data

    # --- Targets ---

    def get_targets(self) -> dict[str, Path]:
        result = {}
        for name, raw_path in self._data.get("targets", {}).items():
            result[name] = self.expand_path(raw_path)
        if not result:
            result["claude"] = Path.home() / ".claude" / "skills"
        return result

    def add_target(self, name: str, path: str) -> None:
        self._data.setdefault("targets", {})[name] = path
        self.save()

    def remove_target(self, name: str) -> None:
        self._data.get("targets", {}).pop(name, None)
        self.save()

    def has_target(self, name: str) -> bool:
        return name in self._data.get("targets", {})

    # --- Repos ---

    def get_repos(self) -> dict[str, dict]:
        return self._data.get("repos", {})

    def add_repo(self, name: str, url: str, branch: str = "main") -> None:
        self._data.setdefault("repos", {})[name] = {"url": url, "branch": branch}
        self.save()

    def has_repo(self, name: str) -> bool:
        return name in self._data.get("repos", {})

    def get_repo(self, name: str) -> Optional[dict]:
        return self._data.get("repos", {}).get(name)

    # --- Skills ---

    def get_skills(self) -> dict[str, dict]:
        return self._data.get("skills", {})

    def get_skill(self, name: str) -> Optional[dict]:
        return self._data.get("skills", {}).get(name)

    def has_skill(self, name: str) -> bool:
        return name in self._data.get("skills", {})

    def add_skill(self, name: str, data: dict) -> None:
        self._data.setdefault("skills", {})[name] = data
        self.save()

    def remove_skill(self, name: str) -> None:
        self._data.get("skills", {}).pop(name, None)
        self.save()

    def update_skill(self, name: str, **fields) -> None:
        skill = self._data.get("skills", {}).get(name)
        if skill:
            skill.update(fields)
            self.save()

    def skill_names(self) -> list[str]:
        return sorted(self._data.get("skills", {}).keys())

    def get_skill_type(self, name: str) -> str:
        skill = self.get_skill(name)
        if not skill:
            return "unknown"
        if skill.get("type") == "git-repo":
            return "git-repo"
        if skill.get("repo") not in (None, "null"):
            return "repo-synced"
        return "local"

    def get_skill_path(self, name: str) -> Optional[Path]:
        skill = self.get_skill(name)
        if not skill or not skill.get("path"):
            return None
        return self.expand_path(skill["path"])

    def get_skills_for_repo(self, repo: str) -> dict[str, dict]:
        return {
            name: data for name, data in self.get_skills().items()
            if data.get("repo") == repo
        }

    # --- Helpers ---

    @staticmethod
    def expand_path(p: str) -> Path:
        return Path(str(p).replace("~", str(Path.home()), 1))

    @staticmethod
    def to_manifest_path(p: Path) -> str:
        home = str(Path.home())
        s = str(p)
        if s.startswith(home):
            return "~" + s[len(home):]
        return s

    @staticmethod
    def repo_to_dir(repo_key: str) -> str:
        return repo_key.replace("/", "-")

    def dir_to_repo(self, dirname: str) -> str:
        for key in self.get_repos():
            if self.repo_to_dir(key) == dirname:
                return key
        return dirname
