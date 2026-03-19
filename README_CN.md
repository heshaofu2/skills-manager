# Skills Manager（中文版）

一个用于管理从 GitHub 仓库安装的 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 及其他 AI Agent 平台 Skills 的命令行工具。支持追踪上游变更、拉取更新、添加和移除 Skills，所有操作通过一个脚本 + manifest 注册表完成。

> English version: [README.md](README.md)

## 架构（v2 — 基于路径）

Skills 保持在原位，不移动、不替换目录。我们只记录它们的路径并追踪上游来源。

```
~/.agents/skills-manager/
├── manifest.json          # 注册表：记录 skill 路径、来源、targets
├── update-skills.sh       # CLI 脚本（所有操作入口）
├── SKILL.md               # Claude Code skill 定义文件
└── repos/                 # 上游 repo 的稀疏克隆（仅作参考）
    ├── anthropics-skills/  # 只检出已注册 skill 的子目录
    ├── vercel-labs-skills/
    └── ...
```

### 三种 Skill 类型

| 类型 | 存储方式 | 更新方式 |
|------|---------|---------|
| **repo-synced** | 普通目录，内容从 repo 子目录同步 | 从稀疏 `repos/` 克隆 `rsync`；按 skill 追踪 `synced_commit` |
| **git-repo** | skill 目录本身就是 git 仓库 | 原地 `git pull` |
| **local** | `repo: null`，用户自管理 | 不更新（私有/基础设施类） |

### 关键设计

- **稀疏检出（Sparse checkout）**：每个 repo 克隆只包含已注册 skill 对应的子目录，最小化磁盘和带宽占用
- **子目录级别 diff**：`check` 命令在 skill 子目录级别比较变更，而非 repo 级别——避免 repo 中其他无关文件变更导致的误报
- **synced_commit 追踪**：每个 repo-synced skill 记录上次同步时的 repo commit hash，实现精确的变更检测
- **多平台 targets**：支持多个 Agent 平台（Claude Code、OpenClaw 等），通过可配置的 target 目录管理

## 安装

```bash
# 1. 克隆本仓库
git clone git@github.com:heshaofu2/skills-manager.git ~/.agents/skills-manager

# 2. 赋予脚本执行权限
chmod +x ~/.agents/skills-manager/update-skills.sh

# 3. 将 skills-manager 链接为 Claude Code skill
ln -sfn ~/.agents/skills-manager ~/.claude/skills/skills-manager

# 4. 运行初始化，扫描并注册已有 skills
~/.agents/skills-manager/update-skills.sh init
```

## 使用方法

### 初始化（首次安装）

扫描所有 target 目录中的已有 skills，通过启发式方法分类（私有、外部 repo、未知来源），并在 manifest 中记录路径。不移动任何文件。

```bash
~/.agents/skills-manager/update-skills.sh init
```

### 列出所有 Skills

```bash
~/.agents/skills-manager/update-skills.sh list
```

### 检查更新

从上游 repo 获取信息，使用子目录级别 diff 检测每个 skill 是否有实际变更。同时检查 git-repo 类型的 skill。

```bash
~/.agents/skills-manager/update-skills.sh check
```

### 拉取更新

```bash
# 拉取所有
~/.agents/skills-manager/update-skills.sh pull

# 拉取指定 repo 或 skill
~/.agents/skills-manager/update-skills.sh pull <repo或skill名称>
```

### 从 GitHub 添加新 Skill

**第一步** — 注册 repo（如已注册则跳过）：

```bash
~/.agents/skills-manager/update-skills.sh add-repo <本地名称> <github-url> [branch]
```

**第二步** — 安装 skill（同步内容到 target 目录，记录路径）：

```bash
~/.agents/skills-manager/update-skills.sh add-skill <skill名称> <repo名称> <repo中的子目录>
```

示例：

```bash
~/.agents/skills-manager/update-skills.sh add-repo anthropics-skills https://github.com/anthropics/skills.git main
~/.agents/skills-manager/update-skills.sh add-skill pdf anthropics-skills skills/pdf
```

### 注册 git-repo 类型 Skill

适用于自身就是 git 仓库的 skill：

```bash
~/.agents/skills-manager/update-skills.sh add-git <名称> <路径> [repo-url]
```

### 注册本地 Skill

适用于无上游来源的私有/基础设施类 skill：

```bash
~/.agents/skills-manager/update-skills.sh add-local <名称> [备注]
```

### 扫描与推荐

扫描 target 目录中未管理的 skills 并提供推荐：

```bash
~/.agents/skills-manager/update-skills.sh scan
```

### 移除 Skill

仅从 manifest 中移除，skill 路径下的文件不会被删除。

```bash
~/.agents/skills-manager/update-skills.sh remove <skill名称>
```

### 管理 Target 平台

```bash
~/.agents/skills-manager/update-skills.sh add-target <名称> <路径>
~/.agents/skills-manager/update-skills.sh remove-target <名称>
```

## Manifest 格式

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
      "note": "私有基础设施 skill"
    }
  }
}
```

## 依赖

- `git`
- `jq`
- `rsync`

## 许可

MIT
