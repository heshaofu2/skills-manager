---
name: skills-manager
description: Manage Claude Code skills installed from GitHub repos. Use when the user wants to check for skill updates, pull latest versions, install new skills from a repo, remove skills, or view skill status and sources. Trigger keywords include "update skills", "check skill updates", "install skill", "add skill", "remove skill", "skill status", "skill versions".
user-invocable: true
argument-hint: "[list|check|pull|add|remove]"
---

# Skill Manager

Manage Claude Code skills that are installed from GitHub repositories. Track upstream changes, pull updates, and add or remove skills — all through a single CLI script backed by a manifest registry.

## Architecture

```
~/.agents/
├── skills-manager/
│   ├── manifest.json          # Registry: maps skills to repo sources
│   ├── update-skills.sh       # CLI script for all operations
│   └── repos/                 # Git clones of upstream repos
│       ├── anthropics-skills/
│       ├── vercel-labs-skills/
│       └── openclaw-skills/
└── skills/                    # Symlinks pointing into repos/ subdirectories
    ├── skill-creator -> ../skills-manager/repos/anthropics-skills/skills/skill-creator
    └── ...
```

`~/.claude/skills/` contains symlinks to `~/.agents/skills/`, which in turn point to the actual repo subdirectories. When a repo is updated via `git pull`, the skill content updates automatically through the symlink chain.

## Script Location

```
~/.agents/skills-manager/update-skills.sh
```

## Available Commands

When the user invokes this skill, run the appropriate subcommand based on `$ARGUMENTS` or the user's intent:

### List all skills

Show all registered skills, their source repos, and current commit hashes.

```bash
~/.agents/skills-manager/update-skills.sh list
```

### Check for updates

Fetch from all upstream repos and report which ones have new commits available. Does NOT pull changes.

```bash
~/.agents/skills-manager/update-skills.sh check
```

### Pull updates

Pull latest changes from all repos (or a specific one). Since skills are symlinked to the repo directories, updates take effect immediately.

```bash
# Pull all repos
~/.agents/skills-manager/update-skills.sh pull

# Pull a specific repo
~/.agents/skills-manager/update-skills.sh pull <repo-name>
```

### Add a new skill from GitHub

This is a two-step process:

**Step 1: Register the repo** (skip if the repo is already registered)

```bash
~/.agents/skills-manager/update-skills.sh add-repo <local-name> <github-url> [branch]
```

Example:
```bash
~/.agents/skills-manager/update-skills.sh add-repo my-skills https://github.com/user/skills.git main
```

**Step 2: Register the skill from that repo**

```bash
~/.agents/skills-manager/update-skills.sh add-skill <skill-name> <repo-name> <subdir-in-repo>
```

Example:
```bash
~/.agents/skills-manager/update-skills.sh add-skill my-tool my-skills skills/my-tool
```

This creates the symlinks in both `~/.agents/skills/` and `~/.claude/skills/` automatically.

### Remove a skill

Remove a skill's symlinks and manifest entry. The repo clone is kept (it may be shared by other skills).

```bash
~/.agents/skills-manager/update-skills.sh remove <skill-name>
```

## Manifest Format

The manifest at `~/.agents/skills-manager/manifest.json` tracks:

- **repos**: Each upstream GitHub repo with its URL and branch
- **skills**: Each skill mapped to a repo name and subdirectory path, with an optional `pinned` flag to skip updates

Skills with `"repo": null` are local-only and not tracked for updates.

## Handling User Requests

- If the user says "update skills" or "check for updates" → run `check`, then ask if they want to `pull`
- If the user says "install a skill from GitHub" → guide them through `add-repo` + `add-skill`
- If the user provides a `$ARGUMENTS` value matching a subcommand (list, check, pull, add, remove) → run it directly
- If `$ARGUMENTS` is empty or unclear → run `list` to show current status
