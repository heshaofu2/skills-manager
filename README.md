# Skills Manager

A CLI tool for managing [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills installed from GitHub repositories. Track upstream changes, pull updates, and add or remove skills — all through a single script backed by a manifest registry.

## Architecture

```
~/.agents/
├── skills-manager/
│   ├── manifest.json          # Registry: maps skills → repo sources
│   ├── update-skills.sh       # CLI script for all operations
│   └── repos/                 # Git clones of upstream repos
│       ├── anthropics-skills/
│       ├── vercel-labs-skills/
│       └── ...
└── skills/                    # Symlinks into repos/ subdirectories
    ├── skill-creator -> ../skills-manager/repos/anthropics-skills/skills/skill-creator
    └── ...

~/.claude/skills/              # Claude Code reads skills from here
├── skills-manager -> ../../.agents/skills/skills-manager
├── skill-creator  -> ../../.agents/skills/skill-creator
└── ...
```

Skills are connected through a two-level symlink chain. When a repo is updated via `git pull`, skill content updates automatically — no manual copying needed.

## Installation

```bash
# 1. Clone this repo
git clone git@github.com:heshaofu2/skills-manager.git ~/.agents/skills-manager

# 2. Make the script executable
chmod +x ~/.agents/skills-manager/update-skills.sh

# 3. Create required directories
mkdir -p ~/.agents/skills ~/.claude/skills

# 4. Link skills-manager itself as a Claude Code skill
ln -sfn ../skills-manager ~/.agents/skills/skills-manager
ln -sfn ../../.agents/skills/skills-manager ~/.claude/skills/skills-manager
```

## Usage

### List all skills

```bash
~/.agents/skills-manager/update-skills.sh list
```

### Check for updates

Fetches from all upstream repos and reports which ones have new commits. Does **not** pull changes.

```bash
~/.agents/skills-manager/update-skills.sh check
```

### Pull updates

```bash
# Pull all repos
~/.agents/skills-manager/update-skills.sh pull

# Pull a specific repo
~/.agents/skills-manager/update-skills.sh pull <repo-name>
```

### Add a new skill from GitHub

**Step 1** — Register the repo (skip if already registered):

```bash
~/.agents/skills-manager/update-skills.sh add-repo <local-name> <github-url> [branch]
```

**Step 2** — Register the skill:

```bash
~/.agents/skills-manager/update-skills.sh add-skill <skill-name> <repo-name> <subdir-in-repo>
```

Example:

```bash
~/.agents/skills-manager/update-skills.sh add-repo my-skills https://github.com/user/skills.git main
~/.agents/skills-manager/update-skills.sh add-skill my-tool my-skills skills/my-tool
```

### Remove a skill

```bash
~/.agents/skills-manager/update-skills.sh remove <skill-name>
```

The repo clone is kept since it may be shared by other skills.

## Manifest Format

`manifest.json` tracks two things:

- **repos** — Each upstream GitHub repo with its URL and branch
- **skills** — Each skill mapped to a repo name and subdirectory, with an optional `pinned` flag to skip updates

Skills with `"repo": null` are local-only and not tracked for updates.

## Requirements

- `git`
- `jq`

## License

MIT

---

# Skills Manager（中文版）

一个用于管理从 GitHub 仓库安装的 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) Skills 的命令行工具。支持追踪上游变更、拉取更新、添加和移除 Skills，所有操作通过一个脚本 + manifest 注册表完成。

## 架构

```
~/.agents/
├── skills-manager/
│   ├── manifest.json          # 注册表：将 skill 映射到 repo 来源
│   ├── update-skills.sh       # CLI 脚本（所有操作入口）
│   └── repos/                 # 上游 repo 的 Git 克隆
│       ├── anthropics-skills/
│       ├── vercel-labs-skills/
│       └── ...
└── skills/                    # 指向 repos/ 子目录的符号链接
    ├── skill-creator -> ../skills-manager/repos/anthropics-skills/skills/skill-creator
    └── ...

~/.claude/skills/              # Claude Code 从这里读取 skills
├── skills-manager -> ../../.agents/skills/skills-manager
├── skill-creator  -> ../../.agents/skills/skill-creator
└── ...
```

Skills 通过两级符号链接连接。当通过 `git pull` 更新 repo 时，skill 内容自动更新，无需手动复制。

## 安装

```bash
# 1. 克隆本仓库
git clone git@github.com:heshaofu2/skills-manager.git ~/.agents/skills-manager

# 2. 赋予脚本执行权限
chmod +x ~/.agents/skills-manager/update-skills.sh

# 3. 创建所需目录
mkdir -p ~/.agents/skills ~/.claude/skills

# 4. 将 skills-manager 自身链接为 Claude Code skill
ln -sfn ../skills-manager ~/.agents/skills/skills-manager
ln -sfn ../../.agents/skills/skills-manager ~/.claude/skills/skills-manager
```

## 使用方法

### 列出所有 Skills

```bash
~/.agents/skills-manager/update-skills.sh list
```

### 检查更新

从所有上游 repo 获取信息，报告哪些有新提交。**不会**拉取变更。

```bash
~/.agents/skills-manager/update-skills.sh check
```

### 拉取更新

```bash
# 拉取所有 repo
~/.agents/skills-manager/update-skills.sh pull

# 拉取指定 repo
~/.agents/skills-manager/update-skills.sh pull <repo-name>
```

### 从 GitHub 添加新 Skill

**第一步** — 注册 repo（如已注册则跳过）：

```bash
~/.agents/skills-manager/update-skills.sh add-repo <本地名称> <github-url> [branch]
```

**第二步** — 注册 skill：

```bash
~/.agents/skills-manager/update-skills.sh add-skill <skill名称> <repo名称> <repo中的子目录>
```

示例：

```bash
~/.agents/skills-manager/update-skills.sh add-repo my-skills https://github.com/user/skills.git main
~/.agents/skills-manager/update-skills.sh add-skill my-tool my-skills skills/my-tool
```

### 移除 Skill

```bash
~/.agents/skills-manager/update-skills.sh remove <skill名称>
```

repo 克隆会保留，因为可能有其他 skill 依赖它。

## Manifest 格式

`manifest.json` 追踪两类信息：

- **repos** — 每个上游 GitHub repo 的 URL 和分支
- **skills** — 每个 skill 映射到 repo 名称和子目录，可选 `pinned` 标记跳过更新

`"repo": null` 表示本地 skill，不追踪上游更新。

## 依赖

- `git`
- `jq`

## 许可

MIT
