---
name: skills-manager
description: Manage agent skills installed from GitHub repos. Use when the user wants to check for skill updates, pull latest versions, install new skills from a repo, remove skills, or view skill status and sources. Trigger keywords include "update skills", "check skill updates", "install skill", "add skill", "remove skill", "skill status", "skill versions".
user-invocable: true
argument-hint: "[status|scan|pull|add|remove]"
---

# Skills Manager

Manage agent skills installed from GitHub repositories, with multi-platform support. Track upstream changes, pull updates, and add or remove skills — all through a Python CLI backed by a manifest registry.

## Architecture (v2 — path-based)

Skills stay where they are. We only record their paths and track upstream sources. No symlinks, no file moving.

```
~/.agents/skills-manager/
├── manifest.json          # Registry: skills with paths, repos, targets
├── SKILL.md               # This file
├── scripts/               # Python CLI
│   ├── main.py            # Entry point
│   ├── manifest.py        # Manifest read/write/query
│   ├── git_ops.py         # Git subprocess wrappers
│   ├── sync.py            # File synchronization
│   ├── scanner.py         # Skill discovery & classification
│   ├── output.py          # ANSI color output
│   └── commands/          # One file per command group
└── repos/                 # Sparse git clones of upstream repos
```

**Sparse checkout**: Each repo clone only contains the subdirectories of registered skills. Adding or removing a skill automatically updates the sparse checkout scope, minimizing disk usage and bandwidth.

### Three skill types

| Type | Storage | Update method |
|------|---------|---------------|
| **repo-synced** | Plain directory (e.g. `~/.claude/skills/pdf/`) | Synced from `repos/` sparse clone; tracks `synced_commit` per skill |
| **git-repo** | The skill dir IS a git repo | `git pull` in-place |
| **local** | `repo: null`, user-managed | Not updated |

## Script Location

```
python3 ~/.agents/skills-manager/scripts/main.py
```

## Available Commands

When the user invokes this skill, run the appropriate subcommand based on `$ARGUMENTS` or the user's intent:

### Status (default)

Show all registered skills with their types, paths, and commit hashes. Add `-r` to also fetch remotes and check for available updates.

```bash
python3 ~/.agents/skills-manager/scripts/main.py status          # local info only
python3 ~/.agents/skills-manager/scripts/main.py status -r       # also check remote for updates
```

### Scan & Discover

Auto-initialize environment (create directories, detect targets) on first run, then scan target directories for unmanaged skills. Interactively classify and register each one using heuristics.

```bash
python3 ~/.agents/skills-manager/scripts/main.py scan
```

### Pull updates

Pull latest changes and sync to skill paths. For repo-synced skills, pulls the repo then syncs to each skill's path. For git-repo skills, runs `git pull` in-place.

```bash
python3 ~/.agents/skills-manager/scripts/main.py pull              # all
python3 ~/.agents/skills-manager/scripts/main.py pull <repo-name>   # specific repo
python3 ~/.agents/skills-manager/scripts/main.py pull <skill-name>  # specific skill
```

### Add a new skill from GitHub

Register a repo source, then run `scan` to interactively discover and install skills from it.

```bash
python3 ~/.agents/skills-manager/scripts/main.py add-repo <name> <url> [branch]
python3 ~/.agents/skills-manager/scripts/main.py scan
```


### Manage target platforms

```bash
python3 ~/.agents/skills-manager/scripts/main.py add-target <name> <path>
python3 ~/.agents/skills-manager/scripts/main.py remove-target <name>
```

## Agent Intelligence Layer

The Python scripts handle mechanical operations. As an AI agent, you add intelligence:

### Origin Discovery for Unknown Skills

When `scan` reports "unknown origin" skills, do NOT simply register as local. Instead:

1. **Read the skill's SKILL.md** — extract author, description, URLs
2. **Search GitHub** via WebSearch — try `"<skill-name>" site:github.com SKILL.md`
3. **Verify the match** — check the repo contains matching content
4. **Act**: found repo → `add-repo` then `scan` to install; not found → `add-local`

### Sensitive Data Detection

When skills are flagged as "private", warn the user about specific sensitive data detected and confirm they should NOT be pushed to public repos.

## Handling User Requests

- "update skills" / "check for updates" → run `status -r`, then ask if they want to `pull`
- Fresh setup or "initialize" / "scan skills" → run `scan`
- "install a skill from GitHub" → `add-repo` then `scan` to discover and install
- "register a skill that is its own git repo" → use `add-git`
- `$ARGUMENTS` matches a subcommand → run it directly
- `$ARGUMENTS` empty → run `status`
