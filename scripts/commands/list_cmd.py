"""List installed skills grouped by category with descriptions."""

import re
from pathlib import Path

from scripts import output
from scripts.manifest import Manifest
from scripts.scanner import collect_skills_from_targets

# Category rules: (pattern, category_label) — first match wins
_CATEGORIES = [
    (r"^seo-", "SEO — Specialized"),
    (r"^seo$", "SEO — Core"),
    (r"^seo-(audit|page|technical|content|plan|google|dataforseo|firecrawl)$", "SEO — Core"),
    (r"osint|offensive|security", "Security / OSINT"),
    (r"impeccable|design|frontend|taste", "Design / Frontend"),
    (r"humanizer|watch|codebase|course", "Content / Media"),
    (r"skills.manager|install.skill", "Skill Management"),
    (r"autoresearch|graphify", "Dev / Research"),
]

_CATEGORY_ORDER = [
    "Dev / Research",
    "Design / Frontend",
    "Content / Media",
    "Security / OSINT",
    "SEO — Core",
    "SEO — Specialized",
    "Skill Management",
    "Other",
]


def _categorize(name: str) -> str:
    for pattern, label in _CATEGORIES:
        if re.search(pattern, name, re.IGNORECASE):
            return label
    return "Other"


def _read_description(skill_md: Path) -> str:
    try:
        content = skill_md.read_text(errors="replace")
        m = re.search(r'^description:\s*[">|]?\s*(.*?)(?=\n\w|\n---)', content, re.MULTILINE | re.DOTALL)
        if m:
            desc = re.sub(r"\s+", " ", m.group(1)).strip().strip('"\'>')
            return desc[:110] + ("…" if len(desc) > 110 else "")
    except Exception:
        pass
    return ""


def run(ctx, manifest: Manifest, args) -> None:
    targets = manifest.get_targets()
    all_names = set(manifest.skill_names())
    all_names.update(collect_skills_from_targets(targets))

    # Build skill data
    skills_by_category: dict[str, list[tuple[str, str, str]]] = {c: [] for c in _CATEGORY_ORDER}

    for name in sorted(all_names):
        category = _categorize(name)

        # Find SKILL.md
        desc = ""
        for target_path in targets.values():
            skill_md = target_path / name / "SKILL.md"
            if skill_md.exists():
                desc = _read_description(skill_md)
                break

        # Get type
        stype = manifest.get_skill_type(name) or "unmanaged"

        skills_by_category.setdefault(category, []).append((name, desc, stype))

    # Print
    output.header(f"Installed Skills ({len(all_names)})")
    print()

    for category in _CATEGORY_ORDER:
        entries = skills_by_category.get(category, [])
        if not entries:
            continue

        print(f"  {output._c(output.BLUE, category)}")
        print(f"  {'─' * 70}")

        name_w = max(len(n) for n, _, _ in entries) + 2
        for name, desc, stype in entries:
            type_tag = f"({stype})" if stype != "unmanaged" else ""
            type_col = output._c(output.YELLOW, f"{type_tag:<14}") if type_tag else " " * 14
            desc_col = desc or output._c(output.RED, "(no description)")
            print(f"  {output._c(output.GREEN, name):<{name_w + 10}}  {type_col}  {desc_col}")

        print()
