# Skills Manager

A CLI tool for managing [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and other AI agent skills installed from GitHub repositories. Track upstream changes, pull updates, and add or remove skills — all through a single script backed by a manifest registry.

> 中文版请查看 [README_CN.md](README_CN.md)

## Architecture (v2 — path-based)

Skills stay where they are. We only record their paths and track upstream sources. No file moving, no directory replacement.

```
~/.agents/skills-manager/
├── manifest.json          # Registry: skills with paths, repos, targets
├── update-skills.sh       # CLI script for all operations
├── SKILL.md               # Claude Code skill definition
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

# 2. Make the script executable
chmod +x ~/.agents/skills-manager/update-skills.sh

# 3. Link skills-manager as a Claude Code skill
ln -sfn ~/.agents/skills-manager ~/.claude/skills/skills-manager

# 4. Run init to scan and register existing skills
~/.agents/skills-manager/update-skills.sh init
```

## Usage

### Initialize (first-time setup)

Scans existing skills across all target directories, classifies them using heuristics (private, external repo, unknown), and registers them in the manifest with their actual paths. No files are moved.

```bash
~/.agents/skills-manager/update-skills.sh init
```

### List all skills

```bash
~/.agents/skills-manager/update-skills.sh list
```

### Check for updates

Fetches from upstream repos and uses subdir-level diff to detect real changes per skill. Also checks git-repo type skills.

```bash
~/.agents/skills-manager/update-skills.sh check
```

### Pull updates

```bash
# Pull all
~/.agents/skills-manager/update-skills.sh pull

# Pull a specific repo or skill
~/.agents/skills-manager/update-skills.sh pull <repo-or-skill-name>
```

### Add a new skill from GitHub

**Step 1** — Register the repo (skip if already registered):

```bash
~/.agents/skills-manager/update-skills.sh add-repo <local-name> <github-url> [branch]
```

**Step 2** — Install the skill (syncs content to target directory, records path):

```bash
~/.agents/skills-manager/update-skills.sh add-skill <skill-name> <repo-name> <subdir-in-repo>
```

Example:

```bash
~/.agents/skills-manager/update-skills.sh add-repo anthropics-skills https://github.com/anthropics/skills.git main
~/.agents/skills-manager/update-skills.sh add-skill pdf anthropics-skills skills/pdf
```

### Register a git-repo skill

For skills that are themselves git repositories:

```bash
~/.agents/skills-manager/update-skills.sh add-git <name> <path> [repo-url]
```

### Register a local skill

For private/infrastructure skills with no upstream:

```bash
~/.agents/skills-manager/update-skills.sh add-local <name> [note]
```

### Scan and recommend

Scan target directories for unmanaged skills and provide recommendations:

```bash
~/.agents/skills-manager/update-skills.sh scan
```

### Remove a skill

Removes from manifest only. Files at the skill's path are NOT deleted.

```bash
~/.agents/skills-manager/update-skills.sh remove <skill-name>
```

### Manage target platforms

```bash
~/.agents/skills-manager/update-skills.sh add-target <name> <path>
~/.agents/skills-manager/update-skills.sh remove-target <name>
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
