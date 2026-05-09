---
name: skills-manager
description: Manage agent skills installed from GitHub repos or ClawHub. Use when the user wants to install a skill from a GitHub URL or ClawHub, check for updates, pull latest versions, remove/uninstall/delete a skill, list installed skills, view skill status, or verify whether skills are up-to-date. Also use when the user queries any skill's metadata: source repository (源仓库), version number (版本号), origin, or update history. Key pattern: when a skill name (like "stock-query", "skill-creator", etc.) appears alongside management verbs — 删掉/删除/卸载/不用了/更新/同步/版本/来源 — this is a skill management request, not a request to run that skill. Similarly, "这个skill" + any metadata or lifecycle question (源仓库/版本号/最新/删掉) is skill management. Bulk operations: "update all skills", "装了哪些skill", "好久没更新". NOT for: creating new skills, editing skill content, debugging skill logic, or non-skill package management (brew, npm, pip).
user-invocable: true
argument-hint: "[list|status|scan|register|install|uninstall|pull]"
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

### List installed skills

Show all installed skills grouped by category (Dev/Research, Design/Frontend, Content/Media, Security/OSINT, SEO, Skill Management) with descriptions and tracking type. Use this when the user wants to browse or see what skills are installed.

```bash
python3 ~/.agents/skills-manager/scripts/main.py list
```

### Status (default)

Show all registered skills with their types, paths, and commit hashes. Add `-r` to also fetch remotes and check for available updates.

```bash
python3 ~/.agents/skills-manager/scripts/main.py status          # local info only
python3 ~/.agents/skills-manager/scripts/main.py status -r       # also check remote for updates
```

### Scan & Discover

Auto-initialize environment on first run, then scan target directories and report unmanaged skills with their detected types. Does NOT register anything by default — the AI agent should present findings to the user and use `register` for selected skills. Use `-y` to auto-register all.

```bash
python3 ~/.agents/skills-manager/scripts/main.py scan            # report only
python3 ~/.agents/skills-manager/scripts/main.py scan -y         # auto-register all
```

### Register a skill

Register a specific unmanaged skill by name. Auto-detects its type (git-repo, clawhub, repo-synced, local).

```bash
python3 ~/.agents/skills-manager/scripts/main.py register <name>
```

### Pull updates

Pull latest changes and sync to skill paths. For repo-synced skills, pulls the repo then syncs to each skill's path. For git-repo skills, runs `git pull` in-place.

```bash
python3 ~/.agents/skills-manager/scripts/main.py pull              # all
python3 ~/.agents/skills-manager/scripts/main.py pull <repo-name>   # specific repo
python3 ~/.agents/skills-manager/scripts/main.py pull <skill-name>  # specific skill
```

### Install a skill from GitHub URL

One command to install: parses the URL, registers the repo if needed, sparse-checkouts the subdir, syncs files, and registers in manifest.

```bash
python3 ~/.agents/skills-manager/scripts/main.py install <github-url> [--name <custom-name>]
```

Supported URL formats:
- `https://github.com/owner/repo/tree/branch/path/to/skill` — subdir of a repo
- `https://github.com/owner/repo` — whole repo is the skill

### Uninstall a skill

Remove from manifest and delete files. Use `--keep-files` to only remove the registration.

```bash
python3 ~/.agents/skills-manager/scripts/main.py uninstall <name>
python3 ~/.agents/skills-manager/scripts/main.py uninstall <name> --keep-files
```

### Add a repo source (advanced)

Register a repo without installing a specific skill. Use `scan` afterwards to discover available skills.

```bash
python3 ~/.agents/skills-manager/scripts/main.py add-repo <name> <url> [branch]
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

- User provides a GitHub URL → run `install <url>`
- "update skills" / "check for updates" → run `status -r`, then ask if they want to `pull`
- Fresh setup / "scan skills" → run `scan`, present findings to user, then `register <name>` for selected skills
- "register all" / quick setup → run `scan -y`
- "delete/remove a skill" → run `uninstall <name>`
- "list skills" / "what skills" / "show skills" → run `list`
- `$ARGUMENTS` matches a subcommand → run it directly
- `$ARGUMENTS` empty → run `status`
