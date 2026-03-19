#!/bin/bash
# update-skills.sh - Manage and update agent skills from GitHub repos
# Usage: update-skills.sh <command> [args]
#
# Architecture: path-based management (v2)
# - Skills stay where they are, we only record their paths
# - repos/ holds upstream clones for reference/sync
# - No symlinks, no file moving, no backups needed

set -euo pipefail

MANAGER_DIR="$HOME/.agents/skills-manager"
MANIFEST="$MANAGER_DIR/manifest.json"
REPOS_DIR="$MANAGER_DIR/repos"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_deps() {
  for cmd in git jq rsync; do
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

# Expand ~ to $HOME in a path string
expand_path() {
  echo "${1/#\~/$HOME}"
}

# Convert repo key (e.g. "anthropics/skills") to directory name (e.g. "anthropics-skills")
repo_to_dir() {
  echo "${1//\//-}"
}

# Convert directory name back to repo key by looking up manifest
dir_to_repo() {
  local dirname="$1"
  # Find the repo key whose repo_to_dir matches this dirname
  local key
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    if [ "$(repo_to_dir "$key")" = "$dirname" ]; then
      echo "$key"
      return
    fi
  done < <(jq -r '.repos | keys[]' "$MANIFEST" 2>/dev/null)
  # Fallback: return dirname as-is
  echo "$dirname"
}

# Read target directories from manifest. Each line: "name|expanded_path"
get_targets() {
  local raw
  raw=$(jq -r '.targets // {} | to_entries[] | "\(.key)|\(.value)"' "$MANIFEST" 2>/dev/null)
  if [ -z "$raw" ]; then
    echo "claude|$HOME/.claude/skills"
    return
  fi
  while IFS='|' read -r tname tpath; do
    echo "$tname|$(expand_path "$tpath")"
  done <<< "$raw"
}

# Get expanded path for a skill from manifest
get_skill_path() {
  local name="$1"
  local raw
  raw=$(jq -r ".skills[\"$name\"].path // \"\"" "$MANIFEST" 2>/dev/null)
  [ -n "$raw" ] && expand_path "$raw" || echo ""
}

# Get skill type: "repo-synced", "git-repo", or "local"
get_skill_type() {
  local name="$1"
  local stype repo
  stype=$(jq -r ".skills[\"$name\"].type // \"\"" "$MANIFEST" 2>/dev/null)
  if [ "$stype" = "git-repo" ]; then
    echo "git-repo"
    return
  fi
  repo=$(jq -r ".skills[\"$name\"].repo // \"null\"" "$MANIFEST" 2>/dev/null)
  if [ "$repo" != "null" ]; then
    echo "repo-synced"
  else
    echo "local"
  fi
}

# Sync content from repos/ to a skill's path
sync_skill() {
  local repo="$1" subdir="$2" dest_path="$3"
  local source="$REPOS_DIR/$(repo_to_dir "$repo")/$subdir/"
  if [ ! -d "$source" ]; then
    echo -e "  ${RED}Error: source $repo/$subdir not found in repos${NC}"
    return 1
  fi
  mkdir -p "$dest_path"
  rsync -a --delete --exclude='.git' "$source" "$dest_path/"
}

# Helper: update manifest with jq expression
manifest_update() {
  local expr="$1"
  local tmp
  tmp=$(mktemp)
  jq "$expr" "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
}

# Update sparse checkout for a repo to include only needed subdirs
update_sparse_checkout() {
  local repo="$1"
  local repo_dir="$REPOS_DIR/$(repo_to_dir "$repo")"
  [ ! -d "$repo_dir/.git" ] && return

  local subdirs=()
  while IFS= read -r subdir; do
    [ -n "$subdir" ] && subdirs+=("$subdir")
  done < <(jq -r ".skills | to_entries[] | select(.value.repo == \"$repo\") | .value.subdir" "$MANIFEST" 2>/dev/null)

  if [ ${#subdirs[@]} -gt 0 ]; then
    (cd "$repo_dir" && git sparse-checkout set "${subdirs[@]}" 2>/dev/null) || true
  fi
}

# Get current HEAD commit of a repo clone
get_repo_head() {
  local repo="$1"
  local repo_dir="$REPOS_DIR/$(repo_to_dir "$repo")"
  [ -d "$repo_dir/.git" ] && (cd "$repo_dir" && git rev-parse HEAD 2>/dev/null) || echo ""
}

# Collect skill names from all target directories (deduped)
collect_skills_from_targets() {
  local seen_str="|"
  while IFS='|' read -r tname tpath; do
    [ ! -d "$tpath" ] && continue
    for entry in "$tpath"/*; do
      [ ! -e "$entry" ] && [ ! -L "$entry" ] && continue
      local name
      name=$(basename "$entry")
      [ -z "$name" ] || [ "$name" = ".DS_Store" ] || [ "$name" = ".claude" ] && continue
      if [[ "$seen_str" != *"|$name|"* ]]; then
        echo "$name"
        seen_str="${seen_str}${name}|"
      fi
    done
  done < <(get_targets)
}

# Find the first target directory that contains a given skill
# Returns: "target_name|full_path_to_skill"
find_skill_in_targets() {
  local skill_name="$1"
  while IFS='|' read -r tname tpath; do
    local spath="$tpath/$skill_name"
    if [ -e "$spath" ] || [ -L "$spath" ]; then
      echo "$tname|$spath"
      return
    fi
  done < <(get_targets)
}

# Heuristic: check if a skill directory contains private/sensitive content
detect_skill_nature() {
  local skill_dir="$1"
  local skill_md="$skill_dir/SKILL.md"

  # Check for sensitive files
  local sensitive_files
  sensitive_files=$(find "$skill_dir" -maxdepth 2 \( -name "*.pem" -o -name ".env" -o -name "*.key" -o -name "credentials*" \) 2>/dev/null | head -1)
  if [ -n "$sensitive_files" ]; then
    echo "private:sensitive-file:$(basename "$sensitive_files")"
    return
  fi

  if [ -f "$skill_md" ]; then
    if grep -qE '\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b' "$skill_md" 2>/dev/null; then
      local ip
      ip=$(grep -oE '\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b' "$skill_md" 2>/dev/null | head -1)
      echo "private:ip:$ip"
      return
    fi
    if grep -qiE '\.pem|\.ssh/|id_rsa|id_ed25519|ssh_key' "$skill_md" 2>/dev/null; then
      echo "private:ssh-key"
      return
    fi
    if grep -qiE 'password|token|secret|credential|api.key' "$skill_md" 2>/dev/null; then
      echo "private:credentials"
      return
    fi

    local github_url
    github_url=$(grep -oE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$skill_md" 2>/dev/null | head -1)
    if [ -n "$github_url" ]; then
      echo "has-source-url:https://$github_url"
      return
    fi
  fi

  echo "clean"
}

# ============================================================
# Commands
# ============================================================

cmd_list() {
  check_deps
  echo -e "${BLUE}=== All Skills ===${NC}"

  # Show targets
  echo -ne "  Targets: "
  local target_names=()
  while IFS='|' read -r tname tpath; do
    target_names+=("$tname")
  done < <(get_targets)
  echo -e "${GREEN}$(IFS=', '; echo "${target_names[*]}")${NC}"
  echo ""

  # Collect skills from manifest + targets
  local all_skills=()
  while IFS= read -r skill; do
    [ -n "$skill" ] && all_skills+=("$skill")
  done < <(jq -r '.skills | keys[]' "$MANIFEST" 2>/dev/null)
  while IFS= read -r skill; do
    [ -n "$skill" ] && all_skills+=("$skill")
  done < <(collect_skills_from_targets)

  IFS=$'\n' all_skills=($(printf '%s\n' "${all_skills[@]}" | sort -u))
  unset IFS

  for skill in "${all_skills[@]}"; do
    if jq -e ".skills[\"$skill\"]" "$MANIFEST" &>/dev/null; then
      local stype path repo subdir note pinned
      stype=$(get_skill_type "$skill")
      path=$(get_skill_path "$skill")
      repo=$(jq -r ".skills[\"$skill\"].repo // \"null\"" "$MANIFEST")
      subdir=$(jq -r ".skills[\"$skill\"].subdir // \"\"" "$MANIFEST")
      note=$(jq -r ".skills[\"$skill\"].note // \"\"" "$MANIFEST")
      pinned=$(jq -r ".skills[\"$skill\"].pinned // false" "$MANIFEST")

      local pin_marker=""
      [ "$pinned" = "true" ] && pin_marker=" [PINNED]"

      local path_status=""
      if [ -n "$path" ]; then
        local epath
        epath=$(expand_path "$path")
        if [ ! -e "$epath" ]; then
          path_status=" ${RED}[MISSING]${NC}"
        fi
      fi

      case "$stype" in
        git-repo)
          local repo_url commit=""
          repo_url=$(jq -r ".skills[\"$skill\"].repo_url // \"\"" "$MANIFEST")
          local epath
          epath=$(expand_path "$path")
          if [ -d "$epath/.git" ]; then
            commit=$(cd "$epath" && git rev-parse --short HEAD 2>/dev/null || echo "???")
          fi
          echo -e "  ${GREEN}$skill${NC} (git-repo) [$commit] $path$path_status$pin_marker"
          ;;
        repo-synced)
          local commit=""
          if [ -d "$REPOS_DIR/$(repo_to_dir "$repo")/.git" ]; then
            commit=$(cd "$REPOS_DIR/$(repo_to_dir "$repo")" && git rev-parse --short HEAD 2>/dev/null || echo "???")
          fi
          echo -e "  ${GREEN}$skill${NC} → $repo/$subdir [$commit] $path$path_status$pin_marker"
          ;;
        local)
          echo -e "  ${YELLOW}$skill${NC} (local) $path $note"
          ;;
      esac
    else
      # Unmanaged
      local found
      found=$(find_skill_in_targets "$skill")
      local info=""
      if [ -n "$found" ]; then
        local tname="${found%%|*}"
        info=" [$tname]"
      fi
      echo -e "  ${RED}$skill${NC}$info [unmanaged]"
    fi
  done
  echo ""
}

cmd_check() {
  check_deps
  echo -e "${BLUE}=== Checking for updates ===${NC}"
  echo ""

  local has_updates=false

  # Check repo-synced skills (by repo)
  local repos
  repos=$(jq -r '.repos | keys[]' "$MANIFEST" 2>/dev/null)
  for repo in $repos; do
    local url branch repo_dir
    url=$(jq -r ".repos[\"$repo\"].url" "$MANIFEST")
    branch=$(jq -r ".repos[\"$repo\"].branch // \"main\"" "$MANIFEST")
    repo_dir="$REPOS_DIR/$(repo_to_dir "$repo")"

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
      echo -e "${YELLOW}$behind new commit(s) in repo${NC}"

      # Check each skill's subdir for actual changes
      local skills_data
      skills_data=$(jq -r ".skills | to_entries[] | select(.value.repo == \"$repo\") | \"\(.key)|\(.value.subdir)|\(.value.synced_commit // \"\")\"" "$MANIFEST")
      while IFS='|' read -r sname subdir synced; do
        [ -z "$sname" ] && continue
        local base_commit="${synced:-$local_commit}"
        if (cd "$repo_dir" && ! git diff --quiet "$base_commit" "origin/$branch" -- "$subdir/" 2>/dev/null); then
          echo -e "    → ${YELLOW}$sname${NC} has changes"
          has_updates=true
        else
          echo -e "    → ${GREEN}$sname${NC} unchanged"
        fi
      done <<< "$skills_data"
    else
      echo -e "${GREEN}up to date${NC}"
    fi
  done

  # Check git-repo type skills
  while IFS= read -r skill; do
    [ -z "$skill" ] && continue
    local stype
    stype=$(get_skill_type "$skill")
    [ "$stype" != "git-repo" ] && continue

    local epath
    epath=$(expand_path "$(get_skill_path "$skill")")
    [ ! -d "$epath/.git" ] && continue

    echo -ne "  Checking $skill (git-repo)... "
    local branch
    branch=$(cd "$epath" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    (cd "$epath" && git fetch origin "$branch" --quiet 2>/dev/null)

    local local_commit remote_commit
    local_commit=$(cd "$epath" && git rev-parse HEAD 2>/dev/null)
    remote_commit=$(cd "$epath" && git rev-parse "origin/$branch" 2>/dev/null) || remote_commit="$local_commit"

    if [ "$local_commit" != "$remote_commit" ]; then
      local behind
      behind=$(cd "$epath" && git rev-list HEAD.."origin/$branch" --count)
      echo -e "${YELLOW}$behind new commit(s) available${NC}"
      has_updates=true
    else
      echo -e "${GREEN}up to date${NC}"
    fi
  done < <(jq -r '.skills | keys[]' "$MANIFEST" 2>/dev/null)

  echo ""
  if [ "$has_updates" = true ]; then
    echo -e "Run ${BLUE}update-skills.sh pull${NC} to update."
  else
    echo "All skills are up to date."
  fi
}

cmd_pull() {
  check_deps
  local target="${1:-}"

  # Pull repo-synced skills
  local repos
  if [ -n "$target" ]; then
    # Target could be a repo name or a skill name
    if jq -e ".repos[\"$target\"]" "$MANIFEST" &>/dev/null; then
      repos="$target"
    elif jq -e ".skills[\"$target\"]" "$MANIFEST" &>/dev/null; then
      local stype
      stype=$(get_skill_type "$target")
      if [ "$stype" = "git-repo" ]; then
        # Pull single git-repo skill
        local epath
        epath=$(expand_path "$(get_skill_path "$target")")
        echo -ne "  Pulling $target (git-repo)... "
        local before after
        before=$(cd "$epath" && git rev-parse --short HEAD)
        (cd "$epath" && git pull --quiet 2>/dev/null)
        after=$(cd "$epath" && git rev-parse --short HEAD)
        if [ "$before" != "$after" ]; then
          echo -e "${GREEN}updated${NC} ($before → $after)"
        else
          echo "already up to date"
        fi
        return
      fi
      repos=$(jq -r ".skills[\"$target\"].repo // \"\"" "$MANIFEST")
      [ -z "$repos" ] && { echo -e "${RED}Skill '$target' has no upstream repo${NC}"; exit 1; }
    else
      echo -e "${RED}Error: '$target' not found as repo or skill${NC}"
      exit 1
    fi
  else
    repos=$(jq -r '.repos | keys[]' "$MANIFEST" 2>/dev/null)
  fi

  # Pull repos and sync
  for repo in $repos; do
    local url branch repo_dir
    url=$(jq -r ".repos[\"$repo\"].url" "$MANIFEST")
    branch=$(jq -r ".repos[\"$repo\"].branch // \"main\"" "$MANIFEST")
    repo_dir="$REPOS_DIR/$(repo_to_dir "$repo")"

    if [ ! -d "$repo_dir/.git" ]; then
      echo -e "  Cloning $repo from $url..."
      git clone "$url" "$repo_dir"
    else
      echo -ne "  Pulling $repo... "
      local before after
      before=$(cd "$repo_dir" && git rev-parse --short HEAD)
      (cd "$repo_dir" && git pull origin "$branch" --quiet 2>/dev/null)
      after=$(cd "$repo_dir" && git rev-parse --short HEAD)
      if [ "$before" != "$after" ]; then
        echo -e "${GREEN}updated${NC} ($before → $after)"
      else
        echo "already up to date"
      fi
    fi

    # Sync to skill paths
    local skills
    skills=$(jq -r ".skills | to_entries[] | select(.value.repo == \"$repo\") | \"\(.key)|\(.value.subdir)|\(.value.path)\"" "$MANIFEST" 2>/dev/null)
    while IFS='|' read -r sname subdir spath; do
      [ -z "$sname" ] && continue
      local pinned
      pinned=$(jq -r ".skills[\"$sname\"].pinned // false" "$MANIFEST")
      [ "$pinned" = "true" ] && { echo -e "    ${YELLOW}$sname${NC} [PINNED] — skipped"; continue; }

      local dest
      dest=$(expand_path "$spath")
      echo -ne "    Syncing $sname... "
      sync_skill "$repo" "$subdir" "$dest"
      # Update synced_commit
      local new_commit
      new_commit=$(get_repo_head "$repo")
      manifest_update ".skills[\"$sname\"].synced_commit = \"$new_commit\""
      echo -e "${GREEN}done${NC}"
    done <<< "$skills"
  done

  # Pull git-repo type skills (if pulling all)
  if [ -z "$target" ]; then
    while IFS= read -r skill; do
      [ -z "$skill" ] && continue
      local stype
      stype=$(get_skill_type "$skill")
      [ "$stype" != "git-repo" ] && continue

      local pinned
      pinned=$(jq -r ".skills[\"$skill\"].pinned // false" "$MANIFEST")
      [ "$pinned" = "true" ] && { echo -e "  ${YELLOW}$skill${NC} [PINNED] — skipped"; continue; }

      local epath
      epath=$(expand_path "$(get_skill_path "$skill")")
      [ ! -d "$epath/.git" ] && continue

      echo -ne "  Pulling $skill (git-repo)... "
      local before after
      before=$(cd "$epath" && git rev-parse --short HEAD)
      (cd "$epath" && git pull --quiet 2>/dev/null)
      after=$(cd "$epath" && git rev-parse --short HEAD)
      if [ "$before" != "$after" ]; then
        echo -e "${GREEN}updated${NC} ($before → $after)"
      else
        echo "already up to date"
      fi
    done < <(jq -r '.skills | keys[]' "$MANIFEST" 2>/dev/null)
  fi
}

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

  manifest_update ".repos[\"$name\"] = {\"url\": \"$url\", \"branch\": \"$branch\"}"

  echo -e "Cloning $name from $url (sparse)..."
  git clone --filter=blob:none --sparse --branch "$branch" "$url" "$REPOS_DIR/$(repo_to_dir "$name")" 2>&1
  echo -e "${GREEN}Done.${NC} Now use 'add-skill' to register skills from this repo."
}

cmd_add_skill() {
  check_deps
  local name="${1:-}" repo="${2:-}" subdir="${3:-}"

  if [ -z "$name" ] || [ -z "$repo" ] || [ -z "$subdir" ]; then
    echo "Usage: update-skills.sh add-skill <name> <repo> <subdir>"
    exit 1
  fi

  if ! jq -e ".repos[\"$repo\"]" "$MANIFEST" &>/dev/null; then
    echo -e "${RED}Error: repo '$repo' not found. Add it first with add-repo.${NC}"
    exit 1
  fi

  # Determine skill path: check if it already exists in a target dir
  local skill_path=""
  local found
  found=$(find_skill_in_targets "$name")
  if [ -n "$found" ]; then
    skill_path="${found#*|}"
    echo -e "  Found existing at: $skill_path"
    echo -e "  ${YELLOW}Warning: local content will be overwritten by upstream.${NC}"
  else
    # Sync to first target directory
    local first_target_path=""
    while IFS='|' read -r tname tpath; do
      if [ -d "$tpath" ]; then
        first_target_path="$tpath"
        break
      fi
    done < <(get_targets)

    if [ -z "$first_target_path" ]; then
      echo -e "${RED}Error: no target directory available. Add one with add-target.${NC}"
      exit 1
    fi

    skill_path="$first_target_path/$name"
    echo -e "  Installing to: $skill_path"
  fi

  # Update sparse checkout to include this subdir
  update_sparse_checkout "$repo"
  # Also ensure the new subdir is checked out (in case manifest wasn't saved yet)
  (cd "$REPOS_DIR/$(repo_to_dir "$repo")" && git sparse-checkout add "$subdir" 2>/dev/null) || true

  local source_dir_check="$REPOS_DIR/$(repo_to_dir "$repo")/$subdir"
  if [ ! -d "$source_dir_check" ]; then
    echo -e "${RED}Error: directory '$subdir' not found in repo '$repo' after sparse checkout${NC}"
    exit 1
  fi

  # Sync content
  sync_skill "$repo" "$subdir" "$skill_path"

  # Record synced commit
  local synced_commit
  synced_commit=$(get_repo_head "$repo")

  # Convert to ~ path for manifest
  local manifest_path="${skill_path/#$HOME/\~}"
  manifest_update ".skills[\"$name\"] = {\"path\": \"$manifest_path\", \"repo\": \"$repo\", \"subdir\": \"$subdir\", \"synced_commit\": \"$synced_commit\", \"pinned\": false}"

  echo -e "${GREEN}Skill '$name' registered at $skill_path${NC}"
}

cmd_add_git() {
  check_deps
  local name="${1:-}" path="${2:-}" repo_url="${3:-}"

  if [ -z "$name" ] || [ -z "$path" ]; then
    echo "Usage: update-skills.sh add-git <name> <path> [repo-url]"
    exit 1
  fi

  local epath
  epath=$(expand_path "$path")
  if [ ! -d "$epath/.git" ]; then
    echo -e "${RED}Error: $path is not a git repository${NC}"
    exit 1
  fi

  if [ -z "$repo_url" ]; then
    repo_url=$(cd "$epath" && git remote get-url origin 2>/dev/null) || repo_url=""
  fi

  local manifest_path="${epath/#$HOME/\~}"
  if [ -n "$repo_url" ]; then
    manifest_update ".skills[\"$name\"] = {\"path\": \"$manifest_path\", \"type\": \"git-repo\", \"repo_url\": \"$repo_url\", \"pinned\": false}"
  else
    manifest_update ".skills[\"$name\"] = {\"path\": \"$manifest_path\", \"type\": \"git-repo\", \"pinned\": false}"
  fi

  echo -e "${GREEN}Skill '$name' registered as git-repo at $path${NC}"
}

cmd_add_local() {
  check_deps
  local name="${1:-}" note="${2:-}"

  if [ -z "$name" ]; then
    echo "Usage: update-skills.sh add-local <skill-name> [note]"
    exit 1
  fi

  if jq -e ".skills[\"$name\"]" "$MANIFEST" &>/dev/null; then
    echo -e "${YELLOW}Skill '$name' already exists in manifest${NC}"
    exit 1
  fi

  # Find path
  local skill_path=""
  local found
  found=$(find_skill_in_targets "$name")
  if [ -n "$found" ]; then
    skill_path="${found#*|}"
  else
    echo -e "${RED}Error: skill '$name' not found in any target directory${NC}"
    exit 1
  fi

  local manifest_path="${skill_path/#$HOME/\~}"
  if [ -n "$note" ]; then
    manifest_update ".skills[\"$name\"] = {\"path\": \"$manifest_path\", \"repo\": null, \"note\": \"$note\"}"
  else
    manifest_update ".skills[\"$name\"] = {\"path\": \"$manifest_path\", \"repo\": null}"
  fi

  echo -e "${GREEN}Skill '$name' registered as local ($skill_path)${NC}"
}

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

  local path repo
  path=$(get_skill_path "$name")
  repo=$(jq -r ".skills[\"$name\"].repo // \"null\"" "$MANIFEST")

  manifest_update "del(.skills[\"$name\"])"

  # Shrink sparse checkout if this was a repo-synced skill
  if [ "$repo" != "null" ] && [ -n "$repo" ]; then
    update_sparse_checkout "$repo"
  fi

  echo -e "${GREEN}Skill '$name' removed from manifest.${NC}"
  if [ -n "$path" ]; then
    echo -e "  Files at $(expand_path "$path") were NOT deleted."
  fi
}

cmd_scan() {
  check_deps
  echo -e "${BLUE}=== Scanning for recommendations ===${NC}"
  echo ""

  local private_skills=()
  local source_url_skills=()
  local repo_match_skills=()
  local unknown_skills=()
  local git_repo_skills=()

  # Part 1: Scan unmanaged skills across all target directories
  local scanned_skills="|"
  while IFS='|' read -r _tname _tpath; do
    [ ! -d "$_tpath" ] && continue
    for entry in "$_tpath"/*; do
      [ ! -e "$entry" ] && [ ! -L "$entry" ] && continue
      local name
      name=$(basename "$entry")
      [ -z "$name" ] || [ "$name" = ".DS_Store" ] || [ "$name" = ".claude" ] && continue

      [[ "$scanned_skills" == *"|$name|"* ]] && continue
      scanned_skills="${scanned_skills}${name}|"
      jq -e ".skills[\"$name\"]" "$MANIFEST" &>/dev/null && continue

      # Resolve actual directory
      local actual_dir="$entry"
      if [ -L "$entry" ]; then
        local link_target
        link_target=$(readlink "$entry")
        if [[ "$link_target" != /* ]]; then
          actual_dir=$(cd "$(dirname "$entry")" && cd "$(dirname "$link_target")" && pwd)/$(basename "$link_target") 2>/dev/null || actual_dir="$entry"
        else
          actual_dir="$link_target"
        fi
      fi

      # Check if it's a git repo
      if [ -d "$actual_dir/.git" ]; then
        local remote_url
        remote_url=$(cd "$actual_dir" && git remote get-url origin 2>/dev/null) || remote_url=""
        git_repo_skills+=("$name|$actual_dir|$remote_url")
        continue
      fi

      # Check if symlink target is inside a git repo
      if [ -L "$entry" ] && [ -d "$actual_dir" ]; then
        local git_root=""
        git_root=$(cd "$actual_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || true
        if [ -n "$git_root" ]; then
          local remote_url rel_in_repo
          remote_url=$(cd "$git_root" && git remote get-url origin 2>/dev/null) || remote_url=""
          rel_in_repo="${actual_dir#$git_root/}"
          git_repo_skills+=("$name|$actual_dir|$remote_url (subdir: $rel_in_repo)")
          continue
        fi
      fi

      # Search in cloned repos
      local matched_repo="" matched_subdir=""
      for repo_dir in "$REPOS_DIR"/*/; do
        [ ! -d "$repo_dir" ] && continue
        local rname
        rname=$(dir_to_repo "$(basename "$repo_dir")")
        if [ -f "$repo_dir/skills/$name/SKILL.md" ]; then
          matched_repo="$rname"
          matched_subdir="skills/$name"
          break
        fi
        for nested in "$repo_dir"/skills/*/"$name"/SKILL.md; do
          if [ -f "$nested" ]; then
            matched_subdir="${nested#$repo_dir/}"
            matched_subdir="${matched_subdir%/SKILL.md}"
            matched_repo="$rname"
            break 2
          fi
        done
      done

      if [ -n "$matched_repo" ]; then
        repo_match_skills+=("$name|$matched_repo|$matched_subdir|$entry")
        continue
      fi

      # Heuristics
      local nature="clean"
      [ -d "$actual_dir" ] && nature=$(detect_skill_nature "$actual_dir")

      case "$nature" in
        private:*)
          private_skills+=("$name|${nature#private:}|$entry")
          ;;
        has-source-url:*)
          source_url_skills+=("$name|${nature#has-source-url:}")
          ;;
        clean)
          unknown_skills+=("$name|$entry")
          ;;
      esac
    done
  done < <(get_targets)

  # Part 2: Available in repos
  local available_in_repos=()
  for repo_dir in "$REPOS_DIR"/*/; do
    [ ! -d "$repo_dir" ] && continue
    local rname
    rname=$(dir_to_repo "$(basename "$repo_dir")")
    [ ! -d "$repo_dir/skills" ] && continue

    for skill_md in "$repo_dir"/skills/*/SKILL.md; do
      [ ! -f "$skill_md" ] && continue
      local skill_subdir="${skill_md#$repo_dir/}"
      skill_subdir="${skill_subdir%/SKILL.md}"
      local skill_name
      skill_name=$(basename "$(dirname "$skill_md")")

      local already=false
      jq -e ".skills[\"$skill_name\"]" "$MANIFEST" &>/dev/null && already=true
      while IFS= read -r rd; do
        [ "$rd" = "$skill_subdir" ] && already=true && break
      done < <(jq -r ".skills | to_entries[] | select(.value.repo == \"$rname\") | .value.subdir" "$MANIFEST" 2>/dev/null)

      $already || available_in_repos+=("$skill_name|$rname|$skill_subdir")
    done
  done

  # Output
  local total=0

  if [ ${#private_skills[@]} -gt 0 ]; then
    echo -e "${YELLOW}[Private/Infrastructure Skills]${NC}"
    for item in "${private_skills[@]}"; do
      IFS='|' read -r sname detail spath <<< "$item"
      echo -e "  ${YELLOW}$sname${NC} — $detail"
      echo -e "    ${BLUE}→ update-skills.sh add-local $sname \"Private infrastructure skill\"${NC}"
    done
    echo -e "  ${RED}Warning: contain credentials. Do NOT push to public repos.${NC}"
    echo ""
    total=$((total + ${#private_skills[@]}))
  fi

  if [ ${#git_repo_skills[@]} -gt 0 ]; then
    echo -e "${BLUE}[Git Repo Skills]${NC}"
    for item in "${git_repo_skills[@]}"; do
      IFS='|' read -r sname spath remote <<< "$item"
      echo -e "  ${BLUE}$sname${NC} at $spath"
      [ -n "$remote" ] && echo -e "    Remote: $remote"
      echo -e "    ${BLUE}→ update-skills.sh add-git $sname $spath${NC}"
    done
    echo ""
    total=$((total + ${#git_repo_skills[@]}))
  fi

  if [ ${#source_url_skills[@]} -gt 0 ]; then
    echo -e "${BLUE}[Skills with Source URL]${NC}"
    for item in "${source_url_skills[@]}"; do
      local sname="${item%%|*}"
      local url="${item#*|}"
      echo -e "  ${BLUE}$sname${NC} — $url"
    done
    echo ""
    total=$((total + ${#source_url_skills[@]}))
  fi

  if [ ${#repo_match_skills[@]} -gt 0 ]; then
    echo -e "${GREEN}[Found in Cloned Repos]${NC}"
    for item in "${repo_match_skills[@]}"; do
      IFS='|' read -r sname rname subdir spath <<< "$item"
      echo -e "  ${GREEN}$sname${NC} — $rname/$subdir"
      echo -e "    ${BLUE}→ update-skills.sh add-skill $sname $rname $subdir${NC}"
    done
    echo ""
    total=$((total + ${#repo_match_skills[@]}))
  fi

  if [ ${#unknown_skills[@]} -gt 0 ]; then
    echo -e "${RED}[Unknown Origin]${NC}"
    for item in "${unknown_skills[@]}"; do
      IFS='|' read -r sname spath <<< "$item"
      echo -e "  ${RED}$sname${NC} at $spath"
      echo -e "    ${BLUE}→ update-skills.sh add-local $sname${NC}"
    done
    echo ""
    total=$((total + ${#unknown_skills[@]}))
  fi

  if [ ${#available_in_repos[@]} -gt 0 ]; then
    echo -e "${GREEN}[Available in Cloned Repos — Not Installed]${NC}"
    local prev_repo="" count=0
    for item in "${available_in_repos[@]}"; do
      IFS='|' read -r sname rname subdir <<< "$item"
      if [ "$rname" != "$prev_repo" ]; then
        [ -n "$prev_repo" ] && echo ""
        echo -e "  ${GREEN}$rname${NC}:"
        prev_repo="$rname"
      fi
      count=$((count + 1))
      [ $count -le 20 ] && echo -e "    $sname  ${BLUE}→ update-skills.sh add-skill $sname $rname $subdir${NC}"
    done
    [ $count -gt 20 ] && echo -e "    ... and $((count - 20)) more"
    echo ""
    total=$((total + count))
  fi

  [ $total -eq 0 ] && echo "All skills are managed. Nothing to recommend." || echo -e "Total: ${YELLOW}$total recommendation(s)${NC}"
}

cmd_init() {
  for cmd in git jq rsync; do
    if ! command -v "$cmd" &>/dev/null; then
      echo -e "${RED}Error: $cmd is required but not installed.${NC}"
      exit 1
    fi
  done

  echo -e "${BLUE}=== Skills Manager Init (v2) ===${NC}"
  echo ""

  # Step 1: Directory structure
  echo -e "${BLUE}[Step 1] Directory structure${NC}"
  mkdir -p "$MANAGER_DIR" "$REPOS_DIR"
  echo -e "  ${GREEN}OK${NC} $MANAGER_DIR"

  # Step 2: Manifest
  echo -e "${BLUE}[Step 2] Manifest${NC}"
  if [ ! -f "$MANIFEST" ]; then
    cat > "$MANIFEST" <<'EOF'
{
  "version": "2.0",
  "targets": {},
  "repos": {},
  "skills": {}
}
EOF
    echo -e "  ${GREEN}Created${NC} manifest.json (v2.0)"
  else
    local ver
    ver=$(jq -r '.version // "1.0"' "$MANIFEST")
    echo -e "  ${GREEN}Exists${NC} manifest.json (v$ver, $(jq '.skills | length' "$MANIFEST") skills)"
  fi

  # Step 3: Targets
  echo -e "${BLUE}[Step 3] Targets${NC}"
  local target_count
  target_count=$(jq '.targets | length' "$MANIFEST")
  if [ "$target_count" -eq 0 ]; then
    local detected=false
    for dir_pair in "$HOME/.claude/skills|claude|Claude Code" "$HOME/.openclaw/skills|openclaw|OpenClaw"; do
      IFS='|' read -r dpath dname dlabel <<< "$dir_pair"
      if [ -d "$dpath" ]; then
        echo -ne "  Found $dpath ($dlabel). Add as target? [Y/n] "
        read -r answer
        if [[ ! "$answer" =~ ^[Nn] ]]; then
          manifest_update ".targets[\"$dname\"] = \"~/${dpath#$HOME/}\""
          echo -e "  ${GREEN}Added${NC} target: $dname"
          detected=true
        fi
      fi
    done
    $detected || echo -e "  ${YELLOW}No agent directories detected. Use add-target later.${NC}"
  else
    echo -e "  ${GREEN}OK${NC} $target_count target(s)"
    while IFS='|' read -r tname tpath; do
      echo -e "    $tname → $tpath"
    done < <(get_targets)
  fi
  echo ""

  # Step 4: Scan
  echo -e "${BLUE}[Step 4] Scanning existing skills${NC}"

  local total_actions=0
  local scanned="|"

  while IFS='|' read -r _tname _tpath; do
    [ ! -d "$_tpath" ] && continue
    for entry in "$_tpath"/*; do
      [ ! -e "$entry" ] && [ ! -L "$entry" ] && continue
      local name
      name=$(basename "$entry")
      [ -z "$name" ] || [ "$name" = ".DS_Store" ] || [ "$name" = ".claude" ] && continue

      [[ "$scanned" == *"|$name|"* ]] && continue
      scanned="${scanned}${name}|"

      if jq -e ".skills[\"$name\"]" "$MANIFEST" &>/dev/null; then
        # Already registered — ensure path is set
        local existing_path
        existing_path=$(jq -r ".skills[\"$name\"].path // \"\"" "$MANIFEST")
        if [ -z "$existing_path" ]; then
          local mpath="${entry/#$HOME/\~}"
          manifest_update ".skills[\"$name\"].path = \"$mpath\""
          echo -e "  ${GREEN}✓${NC} $name — added path"
          total_actions=$((total_actions + 1))
        else
          echo -e "  ${GREEN}✓${NC} $name"
        fi
        continue
      fi

      # Resolve actual dir
      local actual_dir="$entry"
      if [ -L "$entry" ]; then
        local lt
        lt=$(readlink "$entry")
        if [[ "$lt" != /* ]]; then
          actual_dir=$(cd "$(dirname "$entry")" && cd "$(dirname "$lt")" && pwd)/$(basename "$lt") 2>/dev/null || actual_dir="$entry"
        else
          actual_dir="$lt"
        fi
      fi

      local mpath="${entry/#$HOME/\~}"

      # Is it a git repo?
      if [ -d "$actual_dir/.git" ]; then
        local remote_url
        remote_url=$(cd "$actual_dir" && git remote get-url origin 2>/dev/null) || remote_url=""
        echo -ne "  ${BLUE}$name${NC} (git-repo${remote_url:+: $remote_url}) — register? [Y/n] "
        read -r answer
        if [[ ! "$answer" =~ ^[Nn] ]]; then
          local actual_mpath="${actual_dir/#$HOME/\~}"
          if [ -n "$remote_url" ]; then
            manifest_update ".skills[\"$name\"] = {\"path\": \"$actual_mpath\", \"type\": \"git-repo\", \"repo_url\": \"$remote_url\", \"pinned\": false}"
          else
            manifest_update ".skills[\"$name\"] = {\"path\": \"$actual_mpath\", \"type\": \"git-repo\", \"pinned\": false}"
          fi
          echo -e "  ${GREEN}✓${NC} Registered as git-repo"
          total_actions=$((total_actions + 1))
        fi
        continue
      fi

      # Heuristics
      local nature="clean"
      [ -d "$actual_dir" ] && nature=$(detect_skill_nature "$actual_dir")

      case "$nature" in
        private:*)
          echo -ne "  ${YELLOW}$name${NC} (${nature}) — register as local? [Y/n] "
          read -r answer
          if [[ ! "$answer" =~ ^[Nn] ]]; then
            manifest_update ".skills[\"$name\"] = {\"path\": \"$mpath\", \"repo\": null, \"note\": \"Private: ${nature#private:}\"}"
            echo -e "  ${GREEN}✓${NC} Registered as local"
            total_actions=$((total_actions + 1))
          fi
          ;;
        has-source-url:*)
          echo -e "  ${BLUE}$name${NC} — found URL: ${nature#has-source-url:}"
          echo -e "    [1] Register as local for now"
          echo -e "    [2] Skip"
          echo -ne "    Choice [1/2]: "
          read -r choice
          if [ "$choice" = "1" ]; then
            manifest_update ".skills[\"$name\"] = {\"path\": \"$mpath\", \"repo\": null, \"note\": \"Source: ${nature#has-source-url:}\"}"
            echo -e "  ${GREEN}✓${NC} Registered as local"
            total_actions=$((total_actions + 1))
          fi
          ;;
        clean)
          # Try repo match
          local matched=false
          for repo_dir in "$REPOS_DIR"/*/; do
            [ ! -d "$repo_dir" ] && continue
            local rname
            rname=$(dir_to_repo "$(basename "$repo_dir")")
            if [ -f "$repo_dir/skills/$name/SKILL.md" ]; then
              echo -ne "  ${GREEN}$name${NC} → found in $rname — register as repo-synced? [Y/n] "
              read -r answer
              if [[ ! "$answer" =~ ^[Nn] ]]; then
                manifest_update ".skills[\"$name\"] = {\"path\": \"$mpath\", \"repo\": \"$rname\", \"subdir\": \"skills/$name\", \"pinned\": false}"
                echo -e "  ${GREEN}✓${NC} Registered"
                total_actions=$((total_actions + 1))
              fi
              matched=true
              break
            fi
          done
          if ! $matched; then
            echo -e "  ${RED}$name${NC} — unknown origin"
            echo -e "    [1] Register as local  [2] Skip"
            echo -ne "    Choice [1/2]: "
            read -r choice
            if [ "$choice" = "1" ]; then
              manifest_update ".skills[\"$name\"] = {\"path\": \"$mpath\", \"repo\": null}"
              echo -e "  ${GREEN}✓${NC} Registered as local"
              total_actions=$((total_actions + 1))
            fi
          fi
          ;;
      esac
    done
  done < <(get_targets)

  echo ""
  echo -e "${BLUE}=== Init Complete ===${NC}"
  echo -e "  Actions: $total_actions"
  echo -e "  Skills in manifest: $(jq '.skills | length' "$MANIFEST")"
  echo ""
  echo -e "Next: ${BLUE}update-skills.sh list${NC} / ${BLUE}check${NC} / ${BLUE}scan${NC}"
}

cmd_add_target() {
  check_deps
  local name="${1:-}" path="${2:-}"

  if [ -z "$name" ] || [ -z "$path" ]; then
    echo "Usage: update-skills.sh add-target <name> <skills-directory>"
    exit 1
  fi

  if jq -e ".targets[\"$name\"]" "$MANIFEST" &>/dev/null; then
    echo -e "${YELLOW}Target '$name' already exists${NC}"
    exit 1
  fi

  local expanded
  expanded=$(expand_path "$path")
  if [ ! -d "$expanded" ]; then
    echo -ne "Directory $path does not exist. Create it? [y/N] "
    read -r answer
    [[ "$answer" =~ ^[Yy] ]] && mkdir -p "$expanded" || { echo "Aborted."; exit 1; }
  fi

  manifest_update ".targets[\"$name\"] = \"$path\""
  echo -e "${GREEN}Target '$name' added ($path)${NC}"
}

cmd_remove_target() {
  check_deps
  local name="${1:-}"

  if [ -z "$name" ]; then
    echo "Usage: update-skills.sh remove-target <name>"
    exit 1
  fi

  if ! jq -e ".targets[\"$name\"]" "$MANIFEST" &>/dev/null; then
    echo -e "${RED}Error: target '$name' not found${NC}"
    exit 1
  fi

  manifest_update "del(.targets[\"$name\"])"
  echo -e "${GREEN}Target '$name' removed.${NC}"
}

cmd_help() {
  cat <<'EOF'
Usage: update-skills.sh <command> [args]

Commands:
  init                              Initialize: scan and register existing skills
  list                              List all skills and their status
  check                             Check for available updates
  pull [repo-or-skill]              Pull updates and sync to skill paths
  scan                              Scan and recommend unmanaged skills
  add-repo <name> <url> [branch]    Register a new repo source
  add-skill <name> <repo> <subdir>  Install/register a skill from a repo
  add-git <name> <path> [url]       Register a skill that is a git repo
  add-local <name> [note]           Register a local skill (no upstream)
  add-target <name> <path>          Add an agent platform target directory
  remove-target <name>              Remove a target directory
  remove <skill-name>               Unregister a skill (files kept)
  help                              Show this help
EOF
}

# Main
case "${1:-help}" in
  init)           cmd_init ;;
  list)           cmd_list ;;
  check)          cmd_check ;;
  pull)           cmd_pull "${2:-}" ;;
  add-repo)       cmd_add_repo "${2:-}" "${3:-}" "${4:-main}" ;;
  add-skill)      cmd_add_skill "${2:-}" "${3:-}" "${4:-}" ;;
  add-git)        cmd_add_git "${2:-}" "${3:-}" "${4:-}" ;;
  add-local)      cmd_add_local "${2:-}" "${3:-}" ;;
  add-target)     cmd_add_target "${2:-}" "${3:-}" ;;
  remove-target)  cmd_remove_target "${2:-}" ;;
  scan)           cmd_scan ;;
  remove)         cmd_remove "${2:-}" ;;
  help|--help|-h) cmd_help ;;
  *)
    echo -e "${RED}Unknown command: $1${NC}"
    cmd_help
    exit 1
    ;;
esac
