# Skills Manager

A CLI tool for managing [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and other AI agent skills installed from GitHub repositories. Track upstream changes, pull updates, and add or remove skills — all through a single script backed by a manifest registry.

> 中文版请查看 [README_CN.md](README_CN.md)

## Architecture (v2 — path-based)

Skills stay where they are. We only record their paths and track upstream sources. No file moving, no directory replacement.

```
~/.agents/skills-manager/
├── manifest.json          # Registry: skills with paths, repos, targets
├── SKILL.md               # Claude Code skill definition
├── scripts/               # Python CLI
│   ├── main.py            # Entry point
│   ├── manifest.py        # Manifest read/write/query
│   ├── git_ops.py         # Git subprocess wrappers
│   ├── sync.py            # File synchronization
│   ├── scanner.py         # Skill discovery & classification
│   ├── output.py          # ANSI color output
│   └── commands/          # One file per subcommand
└── repos/                 # Sparse git clones of upstream repos (reference only)
    ├── anthropics-skills/  # Only checked-out subdirs for registered skills
    ├── vercel-labs-skills/
    └── ...
```

### Three Skill Types

| Type | Storage | Update Method |
|------|---------|---------------|
| **repo-synced** | Plain directory synced from a repo subdirectory | `rsync` from sparse `repos/` clone; tracks `synced_commit` per skill |
| **git-repo** | The skill directory itself is a git repo | `git pull` in-place |
| **local** | `repo: null`, user-managed | Not updated (private/infrastructure) |

### Key Design Decisions

- **Sparse checkout**: Each repo clone only contains subdirectories of registered skills, minimizing disk usage and bandwidth
- **Subdir-level diff**: `check` compares changes at the skill's subdirectory level, not repo level — avoids false positives when unrelated files in the repo change
- **synced_commit tracking**: Each repo-synced skill records the repo commit hash at last sync, enabling precise change detection
- **Multi-platform targets**: Supports multiple agent platforms (Claude Code, OpenClaw, etc.) via configurable target directories

## Installation

```bash
# 1. Clone this repo
git clone git@github.com:heshaofu2/skills-manager.git ~/.agents/skills-manager

# 2. Link skills-manager as a Claude Code skill
ln -sfn ~/.agents/skills-manager ~/.claude/skills/skills-manager

# 3. Scan and register existing skills
python3 ~/.agents/skills-manager/scripts/main.py scan -y
```

## Usage

All commands use the Python CLI:

```bash
python3 ~/.agents/skills-manager/scripts/main.py <command> [args]
```

### Initialize (first-time setup)

Scans existing skills across all target directories, classifies them using heuristics (private, external repo, unknown), and registers them in the manifest with their actual paths. No files are moved.

```bash
python3 ~/.agents/skills-manager/scripts/main.py scan -y
```

### List all skills

Shows all installed skills grouped by category (Dev/Research, Design/Frontend, Content/Media, Security/OSINT, SEO, Skill Management) with descriptions extracted from each skill's `SKILL.md` and their tracking type.

```bash
python3 ~/.agents/skills-manager/scripts/main.py list
```

Example output:

```
=== Installed Skills (36) ===

  Dev / Research
  ──────────────────────────────────────────────────────────────────────
  autoresearch    (git-repo)   Set up and run an autonomous experiment loop…
  graphify        (local)      any input → knowledge graph → HTML + JSON…

  SEO — Specialized
  ──────────────────────────────────────────────────────────────────────
  seo-audit       (local)      Full website SEO audit with parallel subagent…
  seo-backlinks   (local)      Backlink profile analysis: referring domains…
```

### Check for updates

```bash
python3 ~/.agents/skills-manager/scripts/main.py status -r
```

### Pull updates

```bash
# Pull all
python3 ~/.agents/skills-manager/scripts/main.py pull

# Pull a specific repo or skill
python3 ~/.agents/skills-manager/scripts/main.py pull <repo-or-skill-name>
```

### Install a skill from GitHub

```bash
python3 ~/.agents/skills-manager/scripts/main.py install <github-url>
python3 ~/.agents/skills-manager/scripts/main.py install <github-url> --name <custom-name>
```

Example:

```bash
python3 ~/.agents/skills-manager/scripts/main.py install https://github.com/pbakaus/impeccable
```

### Register an existing skill

```bash
python3 ~/.agents/skills-manager/scripts/main.py register <skill-name>
```

### Add a repo source

```bash
python3 ~/.agents/skills-manager/scripts/main.py add-repo <local-name> <github-url> [branch]
```

### Uninstall a skill

Removes files and manifest entry. Use `--keep-files` to only remove the registration.

```bash
python3 ~/.agents/skills-manager/scripts/main.py uninstall <skill-name>
python3 ~/.agents/skills-manager/scripts/main.py uninstall <skill-name> --keep-files
```

### Manage target platforms

```bash
python3 ~/.agents/skills-manager/scripts/main.py add-target <name> <path>
python3 ~/.agents/skills-manager/scripts/main.py remove-target <name>
```

## Manifest Format

```json
{
  "version": "2.0",
  "targets": { "claude": "~/.claude/skills" },
  "repos": {
    "anthropics-skills": { "url": "https://github.com/anthropics/skills.git", "branch": "main" }
  },
  "skills": {
    "skill-creator": {
      "path": "~/.claude/skills/skill-creator",
      "repo": "anthropics-skills",
      "subdir": "skills/skill-creator",
      "synced_commit": "b0cbd3d...",
      "pinned": false
    },
    "skills-manager": {
      "path": "~/.agents/skills-manager",
      "type": "git-repo",
      "repo_url": "git@github.com:user/skills-manager.git"
    },
    "ssh-server": {
      "path": "~/.claude/skills/ssh-server",
      "repo": null,
      "note": "Private infrastructure skill"
    }
  }
}
```

## Requirements

- `git`
- `jq`
- `rsync`

## License

MIT
