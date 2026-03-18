#!/bin/bash
# update-skills.sh - Manage and update Claude Code skills from GitHub repos
# Usage: update-skills.sh <command> [args]

set -euo pipefail

AGENTS_DIR="$HOME/.agents"
MANAGER_DIR="$AGENTS_DIR/skills-manager"
MANIFEST="$MANAGER_DIR/manifest.json"
REPOS_DIR="$MANAGER_DIR/repos"
SKILLS_DIR="$AGENTS_DIR/skills"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

check_deps() {
  for cmd in git jq; do
    if ! command -v "$cmd" &>/dev/null; then
      echo -e "${RED}Error: $cmd is required but not installed.${NC}"
      exit 1
    fi
  done
  if [ ! -f "$MANIFEST" ]; then
    echo -e "${RED}Error: manifest.json not found at $MANIFEST${NC}"
    exit 1
  fi
}

# List all skills and their status
cmd_list() {
  check_deps
  echo -e "${BLUE}=== Registered Skills ===${NC}"
  echo ""

  local skills
  skills=$(jq -r '.skills | keys[]' "$MANIFEST")

  for skill in $skills; do
    local repo subdir pinned note
    repo=$(jq -r ".skills[\"$skill\"].repo // \"null\"" "$MANIFEST")
    subdir=$(jq -r ".skills[\"$skill\"].subdir // \"\"" "$MANIFEST")
    pinned=$(jq -r ".skills[\"$skill\"].pinned // false" "$MANIFEST")
    note=$(jq -r ".skills[\"$skill\"].note // \"\"" "$MANIFEST")

    if [ "$repo" = "null" ]; then
      echo -e "  ${YELLOW}$skill${NC} (local) $note"
      continue
    fi

    local repo_dir="$REPOS_DIR/$repo"
    local pin_marker=""
    [ "$pinned" = "true" ] && pin_marker=" [PINNED]"

    if [ ! -d "$repo_dir/.git" ]; then
      echo -e "  ${RED}$skill${NC} → $repo/$subdir (not cloned)$pin_marker"
      continue
    fi

    local local_commit
    local_commit=$(cd "$repo_dir" && git rev-parse --short HEAD 2>/dev/null || echo "???")

    echo -e "  ${GREEN}$skill${NC} → $repo/$subdir  [${local_commit}]$pin_marker"
  done
  echo ""
}

# Check for updates without pulling
cmd_check() {
  check_deps
  echo -e "${BLUE}=== Checking for updates ===${NC}"
  echo ""

  local repos has_updates=false
  repos=$(jq -r '.repos | keys[]' "$MANIFEST")

  for repo in $repos; do
    local url branch repo_dir
    url=$(jq -r ".repos[\"$repo\"].url" "$MANIFEST")
    branch=$(jq -r ".repos[\"$repo\"].branch // \"main\"" "$MANIFEST")
    repo_dir="$REPOS_DIR/$repo"

    if [ ! -d "$repo_dir/.git" ]; then
      echo -e "  ${RED}$repo${NC}: not cloned yet"
      continue
    fi

    echo -ne "  Checking $repo... "
    (cd "$repo_dir" && git fetch origin "$branch" --quiet 2>/dev/null)

    local local_commit remote_commit
    local_commit=$(cd "$repo_dir" && git rev-parse HEAD)
    remote_commit=$(cd "$repo_dir" && git rev-parse "origin/$branch")

    if [ "$local_commit" != "$remote_commit" ]; then
      local behind
      behind=$(cd "$repo_dir" && git rev-list HEAD.."origin/$branch" --count)
      echo -e "${YELLOW}$behind new commit(s) available${NC}"
      # Show affected skills
      local skills
      skills=$(jq -r ".skills | to_entries[] | select(.value.repo == \"$repo\") | .key" "$MANIFEST")
      for s in $skills; do
        echo -e "    → $s"
      done
      has_updates=true
    else
      echo -e "${GREEN}up to date${NC}"
    fi
  done

  echo ""
  if [ "$has_updates" = true ]; then
    echo -e "Run ${BLUE}update-skills.sh pull${NC} to update."
  else
    echo "All repos are up to date."
  fi
}

# Pull updates
cmd_pull() {
  check_deps
  local target_repo="${1:-}"

  local repos
  if [ -n "$target_repo" ]; then
    if ! jq -e ".repos[\"$target_repo\"]" "$MANIFEST" &>/dev/null; then
      echo -e "${RED}Error: repo '$target_repo' not found in manifest${NC}"
      exit 1
    fi
    repos="$target_repo"
  else
    repos=$(jq -r '.repos | keys[]' "$MANIFEST")
  fi

  for repo in $repos; do
    local url branch repo_dir
    url=$(jq -r ".repos[\"$repo\"].url" "$MANIFEST")
    branch=$(jq -r ".repos[\"$repo\"].branch // \"main\"" "$MANIFEST")
    repo_dir="$REPOS_DIR/$repo"

    if [ ! -d "$repo_dir/.git" ]; then
      echo -e "  Cloning $repo from $url..."
      git clone "$url" "$repo_dir"
      continue
    fi

    echo -ne "  Pulling $repo... "
    local before after
    before=$(cd "$repo_dir" && git rev-parse --short HEAD)
    (cd "$repo_dir" && git pull origin "$branch" --quiet 2>/dev/null)
    after=$(cd "$repo_dir" && git rev-parse --short HEAD)

    if [ "$before" != "$after" ]; then
      echo -e "${GREEN}updated${NC} ($before → $after)"
    else
      echo -e "already up to date"
    fi
  done
}

# Add a new repo
cmd_add_repo() {
  check_deps
  local name="${1:-}" url="${2:-}" branch="${3:-main}"

  if [ -z "$name" ] || [ -z "$url" ]; then
    echo "Usage: update-skills.sh add-repo <name> <url> [branch]"
    exit 1
  fi

  if jq -e ".repos[\"$name\"]" "$MANIFEST" &>/dev/null; then
    echo -e "${YELLOW}Repo '$name' already exists in manifest${NC}"
    exit 1
  fi

  # Add to manifest
  local tmp
  tmp=$(mktemp)
  jq ".repos[\"$name\"] = {\"url\": \"$url\", \"branch\": \"$branch\"}" "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"

  # Clone
  echo -e "Cloning $name from $url..."
  git clone "$url" "$REPOS_DIR/$name"
  echo -e "${GREEN}Done.${NC} Now use 'add-skill' to register skills from this repo."
}

# Add a new skill
cmd_add_skill() {
  check_deps
  local name="${1:-}" repo="${2:-}" subdir="${3:-}"

  if [ -z "$name" ] || [ -z "$repo" ] || [ -z "$subdir" ]; then
    echo "Usage: update-skills.sh add-skill <name> <repo> <subdir>"
    exit 1
  fi

  if ! jq -e ".repos[\"$repo\"]" "$MANIFEST" &>/dev/null; then
    echo -e "${RED}Error: repo '$repo' not found in manifest. Add it first with add-repo.${NC}"
    exit 1
  fi

  local target_dir="$REPOS_DIR/$repo/$subdir"
  if [ ! -d "$target_dir" ]; then
    echo -e "${RED}Error: directory '$subdir' not found in repo '$repo'${NC}"
    exit 1
  fi

  # Add to manifest
  local tmp
  tmp=$(mktemp)
  jq ".skills[\"$name\"] = {\"repo\": \"$repo\", \"subdir\": \"$subdir\", \"pinned\": false}" "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"

  # Create symlink in skills/
  ln -sfn "../skills-manager/repos/$repo/$subdir" "$SKILLS_DIR/$name"

  # Create symlink in claude skills/ if not exists
  if [ ! -e "$CLAUDE_SKILLS_DIR/$name" ]; then
    ln -sfn "../../.agents/skills/$name" "$CLAUDE_SKILLS_DIR/$name"
    echo -e "  Created symlink in ~/.claude/skills/"
  fi

  echo -e "${GREEN}Skill '$name' registered and linked.${NC}"
}

# Remove a skill
cmd_remove() {
  check_deps
  local name="${1:-}"

  if [ -z "$name" ]; then
    echo "Usage: update-skills.sh remove <skill-name>"
    exit 1
  fi

  if ! jq -e ".skills[\"$name\"]" "$MANIFEST" &>/dev/null; then
    echo -e "${RED}Error: skill '$name' not found in manifest${NC}"
    exit 1
  fi

  # Remove symlinks
  [ -L "$SKILLS_DIR/$name" ] && rm "$SKILLS_DIR/$name"
  [ -L "$CLAUDE_SKILLS_DIR/$name" ] && rm "$CLAUDE_SKILLS_DIR/$name"

  # Remove from manifest
  local tmp
  tmp=$(mktemp)
  jq "del(.skills[\"$name\"])" "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"

  echo -e "${GREEN}Skill '$name' removed.${NC}"
  echo "Note: repo clone was kept (may be used by other skills)."
}

# Usage
cmd_help() {
  cat <<'EOF'
Usage: update-skills.sh <command> [args]

Commands:
  list                              List all skills and their status
  check                             Check for available updates
  pull [repo-name]                  Pull updates (specific repo or all)
  add-repo <name> <url> [branch]    Register a new repo source
  add-skill <name> <repo> <subdir>  Register a new skill from a repo
  remove <skill-name>               Remove a skill
  help                              Show this help
EOF
}

# Main
case "${1:-help}" in
  list)       cmd_list ;;
  check)      cmd_check ;;
  pull)       cmd_pull "${2:-}" ;;
  add-repo)   cmd_add_repo "${2:-}" "${3:-}" "${4:-main}" ;;
  add-skill)  cmd_add_skill "${2:-}" "${3:-}" "${4:-}" ;;
  remove)     cmd_remove "${2:-}" ;;
  help|--help|-h) cmd_help ;;
  *)
    echo -e "${RED}Unknown command: $1${NC}"
    cmd_help
    exit 1
    ;;
esac
