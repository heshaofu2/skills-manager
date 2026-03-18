---
name: skills-manager
description: Manage Claude Code skills installed from GitHub repos. Use when the user wants to check for skill updates, pull latest versions, install new skills from a repo, remove skills, or view skill status and sources. Trigger keywords include "update skills", "check skill updates", "install skill", "add skill", "remove skill", "skill status", "skill versions".
user-invocable: true
argument-hint: "[init|list|check|pull|scan|add|remove]"
---

# Skill Manager

Manage agent skills installed from GitHub repositories, with multi-platform support. Track upstream changes, pull updates, and add or remove skills — all through a single CLI script backed by a manifest registry. Supports multiple agent platforms (Claude Code, OpenClaw, etc.) via configurable targets.

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

Target directories (e.g. `~/.claude/skills/`, `~/.openclaw/skills/`) contain symlinks to `~/.agents/skills/`, which in turn point to the actual repo subdirectories. When a repo is updated via `git pull`, the skill content updates automatically through the symlink chain. Targets are configured in `manifest.json`.

## Script Location

```
~/.agents/skills-manager/update-skills.sh
```

## Available Commands

When the user invokes this skill, run the appropriate subcommand based on `$ARGUMENTS` or the user's intent:

### Initialize (first-time setup or migration)

Scan existing skills across all target directories, classify them using heuristics, and interactively migrate them into the managed system. This includes:
- Creating the directory structure
- Auto-detecting agent platforms (Claude Code, OpenClaw, etc.)
- Classifying skills as private, repo-backed, or unknown
- Cloning source repos and replacing copied directories with symlinks
- Backing up original directories before any changes

```bash
~/.agents/skills-manager/update-skills.sh init
```

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

### Scan and recommend

Automatically scan `~/.claude/skills/` for unmanaged skills and check cloned repos for unregistered skills. Uses heuristics to classify each skill:

- **Private/Infrastructure**: Contains IP addresses, SSH keys, credentials → recommends `add-local`
- **External Repo**: Symlinked to an external git repository → recommends `add-repo` + `add-skill`
- **Source URL Found**: SKILL.md contains a GitHub URL → recommends `add-repo`
- **Found in Cloned Repos**: Name matches a skill in an already-cloned repo → recommends `add-skill`
- **Unknown Origin**: No source detected → recommends `add-local` or manual review

```bash
~/.agents/skills-manager/update-skills.sh scan
```

### Register a local skill

Register a local-only skill in the manifest (no upstream repo tracking). Useful for private infrastructure skills or custom tools.

```bash
~/.agents/skills-manager/update-skills.sh add-local <skill-name> [note]
```

Example:
```bash
~/.agents/skills-manager/update-skills.sh add-local ssh-racknerd "RackNerd VPS SSH skill"
```

### Remove a skill

Remove a skill's symlinks and manifest entry. The repo clone is kept (it may be shared by other skills).

```bash
~/.agents/skills-manager/update-skills.sh remove <skill-name>
```

### Add a target platform

Register a new agent platform's skills directory. Skills will be symlinked to all targets.

```bash
~/.agents/skills-manager/update-skills.sh add-target <name> <skills-directory>
```

Example:
```bash
~/.agents/skills-manager/update-skills.sh add-target openclaw ~/.openclaw/skills
```

### Remove a target platform

```bash
~/.agents/skills-manager/update-skills.sh remove-target <name>
```

## Manifest Format

The manifest at `~/.agents/skills-manager/manifest.json` tracks:

- **targets**: Agent platform skills directories (e.g. `{"claude": "~/.claude/skills"}`)
- **repos**: Each upstream GitHub repo with its URL and branch
- **skills**: Each skill mapped to a repo name and subdirectory path, with an optional `pinned` flag to skip updates

Skills with `"repo": null` are local-only and not tracked for updates.

## Agent Intelligence Layer

The shell script handles mechanical operations (git, symlinks, manifest). As an AI agent, you add intelligence that the script cannot:

### Origin Discovery for Unknown Skills

When `init` or `scan` reports skills as "unknown origin" or "clean" (no source detected), do NOT simply register them as local. Instead:

1. **Read the skill's SKILL.md** — extract author name, description, any URLs or identifiable keywords
2. **Search GitHub** via WebSearch — try queries like:
   - `"<skill-name>" site:github.com SKILL.md`
   - `"<author-name>" skills site:github.com`
   - The skill's description text as search terms
3. **Verify the match** — if a repo is found, check that it contains a matching SKILL.md with similar content
4. **Act on findings**:
   - Found public repo → suggest `add-repo` + `add-skill`
   - Found private repo (or user's own repo) → suggest `add-repo` with SSH URL
   - No repo found → then register as local

### Sensitive Data Detection

When encountering skills flagged as "private" by heuristics, warn the user:
- List the specific sensitive data detected (IPs, key files, credentials)
- Confirm the skill should NOT be pushed to any public repository
- Register as local with a descriptive note

## Handling User Requests

- If this is a fresh setup or user says "initialize" or "setup skills" → run `init`
- If the user says "update skills" or "check for updates" → run `check`, then ask if they want to `pull`
- If the user says "install a skill from GitHub" → guide them through `add-repo` + `add-skill`
- If the user asks "what skills need attention" or "scan skills" → run `scan`
- If the user provides a `$ARGUMENTS` value matching a subcommand (list, check, pull, scan, add, remove) → run it directly
- If `$ARGUMENTS` is empty or unclear → run `list` to show current status
