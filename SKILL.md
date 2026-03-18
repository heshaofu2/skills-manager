---
name: skills-manager
description: Manage agent skills installed from GitHub repos. Use when the user wants to check for skill updates, pull latest versions, install new skills from a repo, remove skills, or view skill status and sources. Trigger keywords include "update skills", "check skill updates", "install skill", "add skill", "remove skill", "skill status", "skill versions".
user-invocable: true
argument-hint: "[init|list|check|pull|scan|add|remove]"
---

# Skills Manager

Manage agent skills installed from GitHub repositories, with multi-platform support. Track upstream changes, pull updates, and add or remove skills — all through a single CLI script backed by a manifest registry.

## Architecture (v2 — path-based)

Skills stay where they are. We only record their paths and track upstream sources. No symlinks, no file moving.

```
~/.agents/skills-manager/
├── manifest.json          # Registry: skills with paths, repos, targets
├── update-skills.sh       # CLI script for all operations
├── SKILL.md               # This file
└── repos/                 # Git clones of upstream repos (reference only)
    ├── anthropics-skills/
    ├── vercel-labs-skills/
    └── ...
```

### Three skill types

| Type | Storage | Update method |
|------|---------|---------------|
| **repo-synced** | Plain directory (e.g. `~/.claude/skills/pdf/`) | `rsync` from `repos/` clone |
| **git-repo** | The skill dir IS a git repo | `git pull` in-place |
| **local** | `repo: null`, user-managed | Not updated |

## Script Location

```
~/.agents/skills-manager/update-skills.sh
```

## Available Commands

When the user invokes this skill, run the appropriate subcommand based on `$ARGUMENTS` or the user's intent:

### Initialize (first-time setup)

Scan existing skills across all target directories, classify them using heuristics, and register them in the manifest with their actual paths. No files are moved.

```bash
~/.agents/skills-manager/update-skills.sh init
```

### List all skills

Show all registered skills with their types, paths, and commit hashes.

```bash
~/.agents/skills-manager/update-skills.sh list
```

### Check for updates

Fetch from upstream repos and report which have new commits. Also checks git-repo type skills.

```bash
~/.agents/skills-manager/update-skills.sh check
```

### Pull updates

Pull latest changes and sync to skill paths. For repo-synced skills, pulls the repo then rsyncs to each skill's path. For git-repo skills, runs `git pull` in-place.

```bash
~/.agents/skills-manager/update-skills.sh pull              # all
~/.agents/skills-manager/update-skills.sh pull <repo-name>   # specific repo
~/.agents/skills-manager/update-skills.sh pull <skill-name>  # specific skill
```

### Scan and recommend

Scan target directories for unmanaged skills. Uses heuristics to classify each one.

```bash
~/.agents/skills-manager/update-skills.sh scan
```

### Add a new skill from GitHub

**Step 1: Register the repo** (skip if already registered)

```bash
~/.agents/skills-manager/update-skills.sh add-repo <name> <url> [branch]
```

**Step 2: Install the skill** — syncs content to target directory and records path

```bash
~/.agents/skills-manager/update-skills.sh add-skill <name> <repo> <subdir>
```

### Register a git-repo skill

For skills that are themselves git repositories (updated via `git pull`):

```bash
~/.agents/skills-manager/update-skills.sh add-git <name> <path> [repo-url]
```

### Register a local skill

For skills with no upstream repo (private/infrastructure):

```bash
~/.agents/skills-manager/update-skills.sh add-local <name> [note]
```

### Remove a skill

Remove from manifest only. Files at the skill's path are NOT deleted.

```bash
~/.agents/skills-manager/update-skills.sh remove <name>
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
  "repos": { "anthropics-skills": { "url": "https://...", "branch": "main" } },
  "skills": {
    "skill-creator": {
      "path": "~/.claude/skills/skill-creator",
      "repo": "anthropics-skills",
      "subdir": "skills/skill-creator",
      "pinned": false
    },
    "skills-manager": {
      "path": "~/.agents/skills-manager",
      "type": "git-repo",
      "repo_url": "git@github.com:user/skills-manager.git",
      "pinned": false
    },
    "ssh-racknerd": {
      "path": "~/.claude/skills/ssh-racknerd",
      "repo": null,
      "note": "Private infrastructure skill"
    }
  }
}
```

## Agent Intelligence Layer

The shell script handles mechanical operations. As an AI agent, you add intelligence:

### Origin Discovery for Unknown Skills

When `init` or `scan` reports "unknown origin" skills, do NOT simply register as local. Instead:

1. **Read the skill's SKILL.md** — extract author, description, URLs
2. **Search GitHub** via WebSearch — try `"<skill-name>" site:github.com SKILL.md`
3. **Verify the match** — check the repo contains matching content
4. **Act**: found repo → `add-repo` + `add-skill`; not found → `add-local`

### Sensitive Data Detection

When skills are flagged as "private", warn the user about specific sensitive data detected and confirm they should NOT be pushed to public repos.

## Handling User Requests

- Fresh setup or "initialize" → run `init`
- "update skills" / "check for updates" → run `check`, then ask if they want to `pull`
- "install a skill from GitHub" → guide through `add-repo` + `add-skill`
- "register a skill that is its own git repo" → use `add-git`
- "scan skills" / "what skills need attention" → run `scan`
- `$ARGUMENTS` matches a subcommand → run it directly
- `$ARGUMENTS` empty → run `list`
