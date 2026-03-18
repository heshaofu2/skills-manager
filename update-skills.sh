#!/bin/bash
# update-skills.sh - Manage and update agent skills from GitHub repos
# Usage: update-skills.sh <command> [args]
# Supports multiple agent platforms via "targets" in manifest.json

set -euo pipefail

AGENTS_DIR="$HOME/.agents"
MANAGER_DIR="$AGENTS_DIR/skills-manager"
MANIFEST="$MANAGER_DIR/manifest.json"
REPOS_DIR="$MANAGER_DIR/repos"
SKILLS_DIR="$AGENTS_DIR/skills"

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

# Read target directories from manifest. Each line: "name|expanded_path"
# Falls back to claude:~/.claude/skills if no targets defined.
get_targets() {
  local raw
  raw=$(jq -r '.targets // {} | to_entries[] | "\(.key)|\(.value)"' "$MANIFEST" 2>/dev/null)
  if [ -z "$raw" ]; then
    echo "claude|$HOME/.claude/skills"
    return
  fi
  while IFS='|' read -r tname tpath; do
    # Expand ~ to $HOME
    tpath="${tpath/#\~/$HOME}"
    echo "$tname|$tpath"
  done <<< "$raw"
}

# Run a callback for each target directory. Usage: for_each_target <callback> [args...]
# Callback receives: target_name target_path [extra args...]
for_each_target() {
  local callback="$1"; shift
  while IFS='|' read -r tname tpath; do
    "$callback" "$tname" "$tpath" "$@"
  done < <(get_targets)
}

# Collect skill names from all target directories (deduped), one per line
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
find_skill_in_targets() {
  local skill_name="$1"
  while IFS='|' read -r tname tpath; do
    local spath="$tpath/$skill_name"
    if [ -e "$spath" ] || [ -L "$spath" ]; then
      echo "$tname|$tpath/$skill_name"
      return
    fi
  done < <(get_targets)
}

# List all skills and their status (scans both manifest and target directories)
cmd_list() {
  check_deps
  echo -e "${BLUE}=== All Skills ===${NC}"

  # Show configured targets
  echo -ne "  Targets: "
  local target_names=()
  while IFS='|' read -r tname tpath; do
    target_names+=("$tname")
  done < <(get_targets)
  echo -e "${GREEN}$(IFS=', '; echo "${target_names[*]}")${NC}"
  echo ""

  # Collect all skill names from both manifest and filesystem
  local all_skills=()

  # From manifest
  while IFS= read -r skill; do
    [ -n "$skill" ] && all_skills+=("$skill")
  done < <(jq -r '.skills | keys[]' "$MANIFEST" 2>/dev/null)

  # From target directories
  while IFS= read -r skill; do
    [ -n "$skill" ] && all_skills+=("$skill")
  done < <(collect_skills_from_targets)

  # Deduplicate and sort
  IFS=$'\n' all_skills=($(printf '%s\n' "${all_skills[@]}" | sort -u))
  unset IFS

  for skill in "${all_skills[@]}"; do
    local in_manifest=false
    jq -e ".skills[\"$skill\"]" "$MANIFEST" &>/dev/null && in_manifest=true

    if $in_manifest; then
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
    else
      # Skill exists in target dir but not in manifest
      local found
      found=$(find_skill_in_targets "$skill")
      local target_info=""
      if [ -n "$found" ]; then
        local tname="${found%%|*}"
        local spath="${found#*|}"
        if [ -L "$spath" ]; then
          local link_target
          link_target=$(readlink "$spath")
          target_info=" → $link_target"
        elif [ -d "$spath" ]; then
          target_info=" (local dir)"
        fi
        target_info="$target_info [$tname]"
      fi

      echo -e "  ${RED}$skill${NC}${target_info} [unmanaged]"
    fi
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

  # Handle existing directory in skills/ (backup + replace)
  if [ -d "$SKILLS_DIR/$name" ] && [ ! -L "$SKILLS_DIR/$name" ]; then
    backup_skill_dir "$name" "$SKILLS_DIR/$name"
    rm -rf "$SKILLS_DIR/$name"
  fi

  # Create symlink in skills/
  ln -sfn "../skills-manager/repos/$repo/$subdir" "$SKILLS_DIR/$name"

  # Create symlinks in all target directories (backup existing dirs)
  while IFS='|' read -r tname tpath; do
    [ ! -d "$tpath" ] && continue
    local tskill="$tpath/$name"
    if [ -d "$tskill" ] && [ ! -L "$tskill" ]; then
      backup_skill_dir "$name" "$tskill"
      rm -rf "$tskill"
    fi
    if [ ! -e "$tskill" ] || [ -L "$tskill" ]; then
      ln -sfn "../../.agents/skills/$name" "$tskill"
      echo -e "  Created symlink in $tname ($tpath)"
    fi
  done < <(get_targets)

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
  # Remove from all target directories
  while IFS='|' read -r tname tpath; do
    [ -L "$tpath/$name" ] && rm "$tpath/$name" && echo -e "  Removed from $tname"
  done < <(get_targets)

  # Remove from manifest
  local tmp
  tmp=$(mktemp)
  jq "del(.skills[\"$name\"])" "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"

  echo -e "${GREEN}Skill '$name' removed.${NC}"
  echo "Note: repo clone was kept (may be used by other skills)."
}

# Register a local skill (no upstream repo)
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

  # Check if skill exists in any target directory
  local found_in_target=""
  while IFS='|' read -r tname tpath; do
    if [ -e "$tpath/$name" ] || [ -L "$tpath/$name" ]; then
      found_in_target="$tname"
      break
    fi
  done < <(get_targets)

  if [ -z "$found_in_target" ]; then
    echo -e "${RED}Error: skill '$name' not found in any target directory${NC}"
    exit 1
  fi

  local tmp
  tmp=$(mktemp)
  if [ -n "$note" ]; then
    jq ".skills[\"$name\"] = {\"repo\": null, \"note\": \"$note\"}" "$MANIFEST" > "$tmp"
  else
    jq ".skills[\"$name\"] = {\"repo\": null}" "$MANIFEST" > "$tmp"
  fi
  mv "$tmp" "$MANIFEST"

  echo -e "${GREEN}Skill '$name' registered as local.${NC}"
}

# Heuristic: check if a skill directory contains private/sensitive content
# Returns: "private" | "has-source-url:<url>" | "clean"
detect_skill_nature() {
  local skill_dir="$1"
  local skill_md="$skill_dir/SKILL.md"

  # Rule 2: Check for sensitive files in the directory
  local sensitive_files
  sensitive_files=$(find "$skill_dir" -maxdepth 2 \( -name "*.pem" -o -name ".env" -o -name "*.key" -o -name "credentials*" \) 2>/dev/null | head -1)
  if [ -n "$sensitive_files" ]; then
    echo "private:sensitive-file:$(basename "$sensitive_files")"
    return
  fi

  # Rule 1 & 3: Analyze SKILL.md content
  if [ -f "$skill_md" ]; then
    # Rule 1: Check for IP addresses + SSH patterns
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

    # Rule 3: Check for GitHub URL
    local github_url
    github_url=$(grep -oE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$skill_md" 2>/dev/null | head -1)
    if [ -n "$github_url" ]; then
      echo "has-source-url:https://$github_url"
      return
    fi
  fi

  echo "clean"
}

# Scan for unmanaged skills and available skills in repos, provide recommendations
cmd_scan() {
  check_deps
  echo -e "${BLUE}=== Scanning for recommendations ===${NC}"
  echo ""

  local private_skills=()
  local source_url_skills=()
  local repo_match_skills=()
  local unknown_skills=()
  local external_repo_skills=()

  # Part 1: Scan unmanaged skills across all target directories
  local scanned_skills="|"
  while IFS='|' read -r _tname _tpath; do
    [ ! -d "$_tpath" ] && continue
    for entry in "$_tpath"/*; do
      [ ! -e "$entry" ] && [ ! -L "$entry" ] && continue
      local name
      name=$(basename "$entry")
      [ -z "$name" ] || [ "$name" = ".DS_Store" ] || [ "$name" = ".claude" ] && continue

      # Skip if already processed or in manifest
      [[ "$scanned_skills" == *"|$name|"* ]] && continue
      scanned_skills="${scanned_skills}${name}|"
      jq -e ".skills[\"$name\"]" "$MANIFEST" &>/dev/null && continue

      # Resolve the actual directory (follow symlinks)
      local actual_dir="$entry"
      local is_symlink=false
      local link_target=""
      if [ -L "$entry" ]; then
        is_symlink=true
        link_target=$(readlink "$entry")
        # Resolve to absolute path
        if [[ "$link_target" != /* ]]; then
          actual_dir=$(cd "$(dirname "$entry")" && cd "$(dirname "$link_target")" && pwd)/$(basename "$link_target")
        else
          actual_dir="$link_target"
        fi
      fi

      # Rule 4: Check if target is inside one of our managed repos
      local found_in_repo=false
      if [ -d "$actual_dir" ]; then
        local resolved_actual
        resolved_actual=$(cd "$actual_dir" 2>/dev/null && pwd) || resolved_actual="$actual_dir"
        local resolved_repos
        resolved_repos=$(cd "$REPOS_DIR" 2>/dev/null && pwd) || resolved_repos="$REPOS_DIR"

        if [[ "$resolved_actual" == "$resolved_repos"/* ]]; then
          # Already points into our repos dir — figure out which repo and subdir
          local rel_path="${resolved_actual#$resolved_repos/}"
          local repo_name="${rel_path%%/*}"
          local subdir="${rel_path#*/}"
          repo_match_skills+=("$name|$repo_name|$subdir|already symlinked into repos/")
          found_in_repo=true
        fi
      fi

      if ! $found_in_repo; then
        # Rule 5: Check if symlink points to an external git repo
        if $is_symlink && [ -d "$actual_dir" ]; then
          local git_root=""
          git_root=$(cd "$actual_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || true
          if [ -n "$git_root" ]; then
            local remote_url
            remote_url=$(cd "$git_root" && git remote get-url origin 2>/dev/null) || remote_url=""
            local rel_in_repo="${actual_dir#$git_root/}"
            external_repo_skills+=("$name|$remote_url|$rel_in_repo|$link_target")
            continue
          fi
        fi

        # Search existing repos for a matching skill name
        local matched_repo="" matched_subdir=""
        for repo_dir in "$REPOS_DIR"/*/; do
          [ ! -d "$repo_dir" ] && continue
          local rname
          rname=$(basename "$repo_dir")
          # Check direct match: skills/<name>/SKILL.md
          if [ -f "$repo_dir/skills/$name/SKILL.md" ]; then
            matched_repo="$rname"
            matched_subdir="skills/$name"
            break
          fi
          # Check nested match: skills/*/<name>/SKILL.md
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
          repo_match_skills+=("$name|$matched_repo|$matched_subdir|found matching directory in repo")
          continue
        fi

        # Apply heuristics on the actual directory
        local nature="clean"
        if [ -d "$actual_dir" ]; then
          nature=$(detect_skill_nature "$actual_dir")
        fi

        case "$nature" in
          private:*)
            local detail="${nature#private:}"
            private_skills+=("$name|$detail")
            ;;
          has-source-url:*)
            local url="${nature#has-source-url:}"
            source_url_skills+=("$name|$url")
            ;;
          clean)
            unknown_skills+=("$name")
            ;;
        esac
      fi
    done
  done < <(get_targets)

  # Part 2: Scan repos for unregistered skills
  local available_in_repos=()
  for repo_dir in "$REPOS_DIR"/*/; do
    [ ! -d "$repo_dir" ] && continue
    local rname
    rname=$(basename "$repo_dir")
    [ ! -d "$repo_dir/skills" ] && continue

    # Scan skills/*/SKILL.md (direct children)
    for skill_md in "$repo_dir"/skills/*/SKILL.md; do
      [ ! -f "$skill_md" ] && continue
      local skill_subdir="${skill_md#$repo_dir/}"
      skill_subdir="${skill_subdir%/SKILL.md}"
      local skill_name
      skill_name=$(basename "$(dirname "$skill_md")")

      # Check if already registered (by subdir match)
      local already_registered=false
      while IFS= read -r registered_subdir; do
        [ "$registered_subdir" = "$skill_subdir" ] && already_registered=true && break
      done < <(jq -r ".skills | to_entries[] | select(.value.repo == \"$rname\") | .value.subdir" "$MANIFEST" 2>/dev/null)

      # Also check by name
      jq -e ".skills[\"$skill_name\"]" "$MANIFEST" &>/dev/null && already_registered=true

      $already_registered || available_in_repos+=("$skill_name|$rname|$skill_subdir")
    done
  done

  # === Output ===

  local total=0

  # Private/Infrastructure skills
  if [ ${#private_skills[@]} -gt 0 ]; then
    echo -e "${YELLOW}[Private/Infrastructure Skills]${NC} (contain sensitive data, recommend local-only)"
    for item in "${private_skills[@]}"; do
      local sname="${item%%|*}"
      local detail="${item#*|}"
      echo -e "  ${YELLOW}$sname${NC} — detected: $detail"
      echo -e "    ${BLUE}→ update-skills.sh add-local $sname \"Private infrastructure skill\"${NC}"
    done
    echo -e "  ${RED}Warning: These skills may contain credentials. Do NOT push to public repos.${NC}"
    echo ""
    total=$((total + ${#private_skills[@]}))
  fi

  # Skills with external git repo (symlinked)
  if [ ${#external_repo_skills[@]} -gt 0 ]; then
    echo -e "${BLUE}[External Repo Skills]${NC} (symlinked to external git repositories)"
    for item in "${external_repo_skills[@]}"; do
      IFS='|' read -r sname remote_url rel_path link_tgt <<< "$item"
      echo -e "  ${BLUE}$sname${NC} → $link_tgt"
      if [ -n "$remote_url" ]; then
        echo -e "    Remote: $remote_url"
        echo -e "    ${BLUE}→ update-skills.sh add-repo ${sname}-repo $remote_url main${NC}"
        echo -e "    ${BLUE}→ update-skills.sh add-skill $sname ${sname}-repo $rel_path${NC}"
      else
        echo -e "    ${BLUE}→ update-skills.sh add-local $sname \"External symlinked skill\"${NC}"
      fi
    done
    echo ""
    total=$((total + ${#external_repo_skills[@]}))
  fi

  # Skills with source URL in SKILL.md
  if [ ${#source_url_skills[@]} -gt 0 ]; then
    echo -e "${BLUE}[Skills with Source URL]${NC} (GitHub URL found in SKILL.md)"
    for item in "${source_url_skills[@]}"; do
      local sname="${item%%|*}"
      local url="${item#*|}"
      echo -e "  ${BLUE}$sname${NC} — source: $url"
      echo -e "    ${BLUE}→ update-skills.sh add-repo ${sname}-repo ${url}.git main${NC}"
    done
    echo ""
    total=$((total + ${#source_url_skills[@]}))
  fi

  # Skills found in already-cloned repos
  if [ ${#repo_match_skills[@]} -gt 0 ]; then
    echo -e "${GREEN}[Found in Cloned Repos]${NC} (already downloaded, just need registration)"
    for item in "${repo_match_skills[@]}"; do
      IFS='|' read -r sname rname subdir note <<< "$item"
      echo -e "  ${GREEN}$sname${NC} — $rname/$subdir ($note)"
      echo -e "    ${BLUE}→ update-skills.sh add-skill $sname $rname $subdir${NC}"
    done
    echo ""
    total=$((total + ${#repo_match_skills[@]}))
  fi

  # Unknown origin
  if [ ${#unknown_skills[@]} -gt 0 ]; then
    echo -e "${RED}[Unknown Origin]${NC} (no source detected, recommend manual review)"
    for sname in "${unknown_skills[@]}"; do
      echo -e "  ${RED}$sname${NC}"
      echo -e "    ${BLUE}→ update-skills.sh add-local $sname${NC}"
    done
    echo ""
    total=$((total + ${#unknown_skills[@]}))
  fi

  # Available in repos but not registered
  if [ ${#available_in_repos[@]} -gt 0 ]; then
    echo -e "${GREEN}[Available in Cloned Repos — Not Registered]${NC}"
    local by_repo=""
    local prev_repo=""
    local count=0
    for item in "${available_in_repos[@]}"; do
      IFS='|' read -r sname rname subdir <<< "$item"
      if [ "$rname" != "$prev_repo" ]; then
        [ -n "$prev_repo" ] && echo ""
        echo -e "  ${GREEN}$rname${NC}:"
        prev_repo="$rname"
      fi
      count=$((count + 1))
      if [ $count -le 20 ]; then
        echo -e "    $sname  ${BLUE}→ update-skills.sh add-skill $sname $rname $subdir${NC}"
      fi
    done
    if [ $count -gt 20 ]; then
      echo -e "    ... and $((count - 20)) more (run with specific repo to see all)"
    fi
    echo ""
    total=$((total + count))
  fi

  if [ $total -eq 0 ]; then
    echo "All skills are managed. Nothing to recommend."
  else
    echo -e "Total: ${YELLOW}$total recommendation(s)${NC}"
  fi
}

# Backup a skill directory before replacing with symlink
# Returns 0 on success
backup_skill_dir() {
  local name="$1" source_path="$2"
  local backup_dir="$MANAGER_DIR/skills-backup"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)

  mkdir -p "$backup_dir"

  # If source is a symlink, no need to backup
  if [ -L "$source_path" ]; then
    return 0
  fi

  if [ -d "$source_path" ]; then
    local backup_path="$backup_dir/${name}_${timestamp}"
    cp -a "$source_path" "$backup_path"
    echo -e "  ${YELLOW}Backed up${NC} $name → skills-backup/${name}_${timestamp}"
    return 0
  fi

  return 1
}

# Replace a skill directory with a symlink (in target dir and skills/)
# Handles backup of existing directories
migrate_skill_to_symlink() {
  local name="$1" repo="$2" subdir="$3"

  local repo_source="$REPOS_DIR/$repo/$subdir"
  if [ ! -d "$repo_source" ]; then
    echo -e "  ${RED}Error: $repo/$subdir not found in repos${NC}"
    return 1
  fi

  # Handle ~/.agents/skills/ symlink
  if [ -d "$SKILLS_DIR/$name" ] && [ ! -L "$SKILLS_DIR/$name" ]; then
    backup_skill_dir "$name" "$SKILLS_DIR/$name"
    rm -rf "$SKILLS_DIR/$name"
  fi
  ln -sfn "../skills-manager/repos/$repo/$subdir" "$SKILLS_DIR/$name"

  # Handle target directories
  while IFS='|' read -r tname tpath; do
    local tskill="$tpath/$name"
    if [ -d "$tskill" ] && [ ! -L "$tskill" ]; then
      backup_skill_dir "$name" "$tskill"
      rm -rf "$tskill"
    fi
    ln -sfn "../../.agents/skills/$name" "$tskill"
  done < <(get_targets)
}

# Initialize skills-manager: scan existing skills, clone repos, migrate to symlinks
cmd_init() {
  for cmd in git jq; do
    if ! command -v "$cmd" &>/dev/null; then
      echo -e "${RED}Error: $cmd is required but not installed.${NC}"
      exit 1
    fi
  done

  echo -e "${BLUE}=== Skills Manager Init ===${NC}"
  echo ""

  # Step 1: Create directory structure
  echo -e "${BLUE}[Step 1] Directory structure${NC}"
  mkdir -p "$MANAGER_DIR" "$REPOS_DIR" "$SKILLS_DIR" "$MANAGER_DIR/skills-backup"
  echo -e "  ${GREEN}OK${NC} $MANAGER_DIR"

  # Step 2: Initialize manifest if needed
  echo -e "${BLUE}[Step 2] Manifest${NC}"
  if [ ! -f "$MANIFEST" ]; then
    cat > "$MANIFEST" <<'MANIFEST_EOF'
{
  "version": "1.1",
  "targets": {},
  "repos": {},
  "skills": {}
}
MANIFEST_EOF
    echo -e "  ${GREEN}Created${NC} manifest.json"
  else
    echo -e "  ${GREEN}Exists${NC} manifest.json ($(jq '.skills | length' "$MANIFEST") skills registered)"
  fi

  # Step 3: Configure targets
  echo -e "${BLUE}[Step 3] Targets${NC}"
  local target_count
  target_count=$(jq '.targets | length' "$MANIFEST")
  if [ "$target_count" -eq 0 ]; then
    # Auto-detect common agent skill directories
    local detected=false
    if [ -d "$HOME/.claude/skills" ]; then
      echo -ne "  Found ~/.claude/skills (Claude Code). Add as target? [Y/n] "
      read -r answer
      if [[ ! "$answer" =~ ^[Nn] ]]; then
        local tmp; tmp=$(mktemp)
        jq '.targets["claude"] = "~/.claude/skills"' "$MANIFEST" > "$tmp"
        mv "$tmp" "$MANIFEST"
        echo -e "  ${GREEN}Added${NC} target: claude"
        detected=true
      fi
    fi
    if [ -d "$HOME/.openclaw/skills" ]; then
      echo -ne "  Found ~/.openclaw/skills (OpenClaw). Add as target? [Y/n] "
      read -r answer
      if [[ ! "$answer" =~ ^[Nn] ]]; then
        local tmp; tmp=$(mktemp)
        jq '.targets["openclaw"] = "~/.openclaw/skills"' "$MANIFEST" > "$tmp"
        mv "$tmp" "$MANIFEST"
        echo -e "  ${GREEN}Added${NC} target: openclaw"
        detected=true
      fi
    fi
    if ! $detected; then
      echo -e "  ${YELLOW}No agent skill directories detected.${NC}"
      echo -e "  Use ${BLUE}update-skills.sh add-target <name> <path>${NC} to add one later."
    fi
  else
    echo -e "  ${GREEN}OK${NC} $target_count target(s) configured"
    while IFS='|' read -r tname tpath; do
      echo -e "    $tname → $tpath"
    done < <(get_targets)
  fi
  echo ""

  # Step 4: Scan existing skills
  echo -e "${BLUE}[Step 4] Scanning existing skills${NC}"

  local to_migrate=()      # "name|repo_url|subdir" — need clone + symlink
  local to_register_local=() # "name|reason"
  local to_skip=()         # "name|reason" — already managed
  local to_ask=()          # "name" — can't determine automatically
  local external_repos=()  # "name|remote_url|rel_path|link_target"

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

      # Already in manifest
      if jq -e ".skills[\"$name\"]" "$MANIFEST" &>/dev/null; then
        to_skip+=("$name|already registered")
        continue
      fi

      # Resolve actual directory
      local actual_dir="$entry"
      local is_symlink=false
      local link_target=""
      if [ -L "$entry" ]; then
        is_symlink=true
        link_target=$(readlink "$entry")
        if [[ "$link_target" != /* ]]; then
          actual_dir=$(cd "$(dirname "$entry")" && cd "$(dirname "$link_target")" && pwd)/$(basename "$link_target") 2>/dev/null || actual_dir="$entry"
        else
          actual_dir="$link_target"
        fi
      fi

      # Check if already pointing into our repos/
      if [ -d "$actual_dir" ]; then
        local resolved_actual resolved_repos
        resolved_actual=$(cd "$actual_dir" 2>/dev/null && pwd) || resolved_actual="$actual_dir"
        resolved_repos=$(cd "$REPOS_DIR" 2>/dev/null && pwd) || resolved_repos="$REPOS_DIR"
        if [[ "$resolved_actual" == "$resolved_repos"/* ]]; then
          local rel_path="${resolved_actual#$resolved_repos/}"
          local rn="${rel_path%%/*}"
          local sd="${rel_path#*/}"
          to_skip+=("$name|already symlinked to repos/$rn/$sd")
          continue
        fi
      fi

      # Check if symlink to external git repo
      if $is_symlink && [ -d "$actual_dir" ]; then
        local git_root=""
        git_root=$(cd "$actual_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || true
        if [ -n "$git_root" ]; then
          local remote_url
          remote_url=$(cd "$git_root" && git remote get-url origin 2>/dev/null) || remote_url=""
          local rel_in_repo="${actual_dir#$git_root/}"
          external_repos+=("$name|$remote_url|$rel_in_repo|$link_target")
          continue
        fi
      fi

      # Heuristic classification
      local nature="clean"
      if [ -d "$actual_dir" ]; then
        nature=$(detect_skill_nature "$actual_dir")
      fi

      case "$nature" in
        private:*)
          to_register_local+=("$name|$nature")
          ;;
        has-source-url:*)
          local url="${nature#has-source-url:}"
          to_ask+=("$name|source-url:$url")
          ;;
        clean)
          # Try to match in known repo patterns
          # Common skill repos to try
          local found_match=false
          for repo_dir in "$REPOS_DIR"/*/; do
            [ ! -d "$repo_dir" ] && continue
            local rname
            rname=$(basename "$repo_dir")
            if [ -f "$repo_dir/skills/$name/SKILL.md" ]; then
              to_migrate+=("$name|$rname|skills/$name|already-cloned")
              found_match=true
              break
            fi
            for nested in "$repo_dir"/skills/*/"$name"/SKILL.md; do
              if [ -f "$nested" ]; then
                local sd="${nested#$repo_dir/}"
                sd="${sd%/SKILL.md}"
                to_migrate+=("$name|$rname|$sd|already-cloned")
                found_match=true
                break 2
              fi
            done
          done
          $found_match || to_ask+=("$name|unknown")
          ;;
      esac
    done
  done < <(get_targets)

  echo ""

  # Step 5: Report and execute
  local total_actions=0

  # Already managed
  if [ ${#to_skip[@]} -gt 0 ]; then
    echo -e "${GREEN}[Already Managed]${NC} ${#to_skip[@]} skill(s)"
    for item in "${to_skip[@]}"; do
      echo -e "  ${GREEN}✓${NC} ${item%%|*}"
    done
    echo ""
  fi

  # Auto-register private/local skills
  if [ ${#to_register_local[@]} -gt 0 ]; then
    echo -e "${YELLOW}[Private/Infrastructure Skills]${NC} — auto-registering as local"
    for item in "${to_register_local[@]}"; do
      local sname="${item%%|*}"
      local detail="${item#*|}"
      echo -ne "  ${YELLOW}$sname${NC} ($detail) — register as local? [Y/n] "
      read -r answer
      if [[ ! "$answer" =~ ^[Nn] ]]; then
        local tmp; tmp=$(mktemp)
        jq ".skills[\"$sname\"] = {\"repo\": null, \"note\": \"Private: $detail\"}" "$MANIFEST" > "$tmp"
        mv "$tmp" "$MANIFEST"
        echo -e "  ${GREEN}✓${NC} Registered as local"
        total_actions=$((total_actions + 1))
      fi
    done
    echo ""
  fi

  # Migrate skills found in already-cloned repos
  if [ ${#to_migrate[@]} -gt 0 ]; then
    echo -e "${GREEN}[Found in Cloned Repos]${NC} — will backup & replace with symlinks"
    for item in "${to_migrate[@]}"; do
      IFS='|' read -r sname rname subdir note <<< "$item"
      echo -ne "  ${GREEN}$sname${NC} → $rname/$subdir — migrate? [Y/n] "
      read -r answer
      if [[ ! "$answer" =~ ^[Nn] ]]; then
        migrate_skill_to_symlink "$sname" "$rname" "$subdir"
        local tmp; tmp=$(mktemp)
        jq ".skills[\"$sname\"] = {\"repo\": \"$rname\", \"subdir\": \"$subdir\", \"pinned\": false}" "$MANIFEST" > "$tmp"
        mv "$tmp" "$MANIFEST"
        echo -e "  ${GREEN}✓${NC} Migrated"
        total_actions=$((total_actions + 1))
      fi
    done
    echo ""
  fi

  # External repo skills
  if [ ${#external_repos[@]} -gt 0 ]; then
    echo -e "${BLUE}[External Repo Skills]${NC} — symlinked to external git repos"
    for item in "${external_repos[@]}"; do
      IFS='|' read -r sname remote_url rel_path link_tgt <<< "$item"
      echo -e "  ${BLUE}$sname${NC} → $link_tgt"
      if [ -n "$remote_url" ]; then
        echo -e "    Remote: $remote_url"
        echo -ne "    Clone and track via skills-manager? [y/N] "
        read -r answer
        if [[ "$answer" =~ ^[Yy] ]]; then
          # Derive a repo name
          local repo_name
          repo_name=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+)/([^/.]+)(\.git)?$|\1-\2|')
          if ! jq -e ".repos[\"$repo_name\"]" "$MANIFEST" &>/dev/null; then
            local tmp; tmp=$(mktemp)
            jq ".repos[\"$repo_name\"] = {\"url\": \"$remote_url\", \"branch\": \"main\"}" "$MANIFEST" > "$tmp"
            mv "$tmp" "$MANIFEST"
            if [ ! -d "$REPOS_DIR/$repo_name" ]; then
              echo -e "    Cloning $repo_name..."
              git clone "$remote_url" "$REPOS_DIR/$repo_name" 2>&1 | sed 's/^/    /'
            fi
          fi
          migrate_skill_to_symlink "$sname" "$repo_name" "$rel_path"
          local tmp; tmp=$(mktemp)
          jq ".skills[\"$sname\"] = {\"repo\": \"$repo_name\", \"subdir\": \"$rel_path\", \"pinned\": false}" "$MANIFEST" > "$tmp"
          mv "$tmp" "$MANIFEST"
          echo -e "  ${GREEN}✓${NC} Migrated to tracked"
          total_actions=$((total_actions + 1))
        else
          echo -ne "    Register as local instead? [Y/n] "
          read -r answer2
          if [[ ! "$answer2" =~ ^[Nn] ]]; then
            local tmp; tmp=$(mktemp)
            jq ".skills[\"$sname\"] = {\"repo\": null, \"note\": \"External: $remote_url\"}" "$MANIFEST" > "$tmp"
            mv "$tmp" "$MANIFEST"
            echo -e "  ${GREEN}✓${NC} Registered as local"
            total_actions=$((total_actions + 1))
          fi
        fi
      else
        echo -ne "    No remote URL. Register as local? [Y/n] "
        read -r answer
        if [[ ! "$answer" =~ ^[Nn] ]]; then
          local tmp; tmp=$(mktemp)
          jq ".skills[\"$sname\"] = {\"repo\": null, \"note\": \"External symlink: $link_tgt\"}" "$MANIFEST" > "$tmp"
          mv "$tmp" "$MANIFEST"
          echo -e "  ${GREEN}✓${NC} Registered as local"
          total_actions=$((total_actions + 1))
        fi
      fi
    done
    echo ""
  fi

  # Skills needing manual decision
  if [ ${#to_ask[@]} -gt 0 ]; then
    echo -e "${RED}[Needs Manual Decision]${NC}"
    for item in "${to_ask[@]}"; do
      local sname="${item%%|*}"
      local detail="${item#*|}"
      echo -e "  ${RED}$sname${NC} ($detail)"
      echo -e "    [1] Register as local (no upstream tracking)"
      echo -e "    [2] Skip for now"
      echo -ne "    Choice [1/2]: "
      read -r choice
      case "$choice" in
        1)
          local tmp; tmp=$(mktemp)
          jq ".skills[\"$sname\"] = {\"repo\": null}" "$MANIFEST" > "$tmp"
          mv "$tmp" "$MANIFEST"
          echo -e "  ${GREEN}✓${NC} Registered as local"
          total_actions=$((total_actions + 1))
          ;;
        *)
          echo -e "  Skipped"
          ;;
      esac
    done
    echo ""
  fi

  # Summary
  echo -e "${BLUE}=== Init Complete ===${NC}"
  echo -e "  Actions taken: $total_actions"
  echo -e "  Total skills in manifest: $(jq '.skills | length' "$MANIFEST")"
  echo -e "  Backups: $MANAGER_DIR/skills-backup/"
  echo ""
  echo -e "Next steps:"
  echo -e "  ${BLUE}update-skills.sh list${NC}   — view all skills"
  echo -e "  ${BLUE}update-skills.sh check${NC}  — check for updates"
  echo -e "  ${BLUE}update-skills.sh scan${NC}   — find more skills in cloned repos"
}

# Add a target directory (agent platform)
cmd_add_target() {
  check_deps
  local name="${1:-}" path="${2:-}"

  if [ -z "$name" ] || [ -z "$path" ]; then
    echo "Usage: update-skills.sh add-target <name> <skills-directory>"
    echo "Example: update-skills.sh add-target openclaw ~/.openclaw/skills"
    exit 1
  fi

  if jq -e ".targets[\"$name\"]" "$MANIFEST" &>/dev/null; then
    echo -e "${YELLOW}Target '$name' already exists${NC}"
    exit 1
  fi

  # Expand ~ for validation but store as-is
  local expanded="${path/#\~/$HOME}"
  if [ ! -d "$expanded" ]; then
    echo -ne "Directory $path does not exist. Create it? [y/N] "
    read -r answer
    if [[ "$answer" =~ ^[Yy] ]]; then
      mkdir -p "$expanded"
    else
      echo "Aborted."
      exit 1
    fi
  fi

  local tmp
  tmp=$(mktemp)
  jq ".targets[\"$name\"] = \"$path\"" "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"

  echo -e "${GREEN}Target '$name' added ($path)${NC}"

  # Offer to create symlinks for existing managed skills
  local skill_count
  skill_count=$(jq -r '.skills | keys | length' "$MANIFEST")
  if [ "$skill_count" -gt 0 ]; then
    echo -e "Creating symlinks for existing skills in $name..."
    while IFS= read -r skill; do
      if [ -e "$SKILLS_DIR/$skill" ] || [ -L "$SKILLS_DIR/$skill" ]; then
        if [ ! -e "$expanded/$skill" ]; then
          ln -sfn "../../.agents/skills/$skill" "$expanded/$skill"
          echo -e "  ${GREEN}$skill${NC} → linked"
        fi
      fi
    done < <(jq -r '.skills | keys[]' "$MANIFEST")
  fi
}

# Remove a target directory
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

  local tmp
  tmp=$(mktemp)
  jq "del(.targets[\"$name\"])" "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"

  echo -e "${GREEN}Target '$name' removed from manifest.${NC}"
  echo "Note: Symlinks in the target directory were not removed."
}

# Usage
cmd_help() {
  cat <<'EOF'
Usage: update-skills.sh <command> [args]

Commands:
  init                              Initialize: scan, classify, and migrate existing skills
  list                              List all skills and their status
  check                             Check for available updates
  pull [repo-name]                  Pull updates (specific repo or all)
  scan                              Scan and recommend unmanaged skills
  add-repo <name> <url> [branch]    Register a new repo source
  add-skill <name> <repo> <subdir>  Register a new skill from a repo
  add-local <name> [note]           Register a local skill (no upstream repo)
  add-target <name> <path>          Add an agent platform target directory
  remove-target <name>              Remove a target directory
  remove <skill-name>               Remove a skill
  help                              Show this help
EOF
}

# Main
case "${1:-help}" in
  init)       cmd_init ;;
  list)       cmd_list ;;
  check)      cmd_check ;;
  pull)       cmd_pull "${2:-}" ;;
  add-repo)   cmd_add_repo "${2:-}" "${3:-}" "${4:-main}" ;;
  add-skill)  cmd_add_skill "${2:-}" "${3:-}" "${4:-}" ;;
  scan)           cmd_scan ;;
  add-local)      cmd_add_local "${2:-}" "${3:-}" ;;
  add-target)     cmd_add_target "${2:-}" "${3:-}" ;;
  remove-target)  cmd_remove_target "${2:-}" ;;
  remove)         cmd_remove "${2:-}" ;;
  help|--help|-h) cmd_help ;;
  *)
    echo -e "${RED}Unknown command: $1${NC}"
    cmd_help
    exit 1
    ;;
esac
