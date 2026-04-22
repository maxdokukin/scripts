#!/usr/bin/env zsh

# 1. Validation
if [[ -z "$1" ]]; then
    echo "Usage: $0 <path_to_repos_folder>"
    exit 1
fi

TARGET_DIR=$1

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: Directory '$TARGET_DIR' not found."
    exit 1
fi

if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI ('gh') is not installed."
    exit 1
fi

echo "🔍 Fetching repository list from GitHub..."

# 2. Get list of remote repos (names only)
remote_repos=($(gh repo list --limit 1000 --json name --template '{{range .}}{{.name}}{{"\n"}}{{end}}'))

# 3. Get list of local directories
local_dirs=($TARGET_DIR/*(/N:t))

# 4. Map the lists using associative arrays
typeset -A in_git
typeset -A in_local

for repo in "${remote_repos[@]}"; do
    in_git[$repo]=1
done

for dir in "${local_dirs[@]}"; do
    in_local[$dir]=1
done

# Combine both arrays to get a unique list of all project slugs
all_keys=($(print -l "${remote_repos[@]}" "${local_dirs[@]}" | sort -u | awk 'NF'))

# 5. Print the Report
echo "\n📊 Verification Report"
echo "---------------------------------------------------------------------------------------------------------------------"
printf "%-55s | %-15s | %-15s | %-20s\n" "proj-slug" "present_locally" "present_git" "synced"
echo "--------------------------------------------------------|-----------------|-----------------|----------------------"

for proj in "${all_keys[@]}"; do
    
    # Check local status
    if [[ -n "${in_local[$proj]}" ]]; then 
        loc="✅"
    else 
        loc="❌"
    fi
    
    # Check git status
    if [[ -n "${in_git[$proj]}" ]]; then 
        git="✅"
    else 
        git="❌"
    fi
    
    # Check Sync status
    synced="➖"
    details_msg=""
    
    if [[ "$loc" == "✅" && "$git" == "✅" ]]; then
        repo_path="$TARGET_DIR/$proj"
        
        if [[ ! -d "$repo_path/.git" ]]; then
            synced="❌ (No .git)"
        else
            # Use git -C to run commands against the repo path without needing to cd into it
            git_status_porcelain=$(git -C "$repo_path" status --porcelain 2>/dev/null)
            branch_status=$(git -C "$repo_path" status -sb 2>/dev/null | head -n 1)
            
            if [[ -n "$git_status_porcelain" ]]; then
                synced="❌ (Dirty)"
                details_msg="$git_status_porcelain"
            elif [[ "$branch_status" == *\[ahead*,*behind* ]]; then
                synced="❌ (Diverged)"
                details_msg="$branch_status"
            elif [[ "$branch_status" == *\[ahead* ]]; then
                synced="❌ (Needs Push)"
                details_msg="$branch_status"
            elif [[ "$branch_status" == *\[behind* ]]; then
                synced="❌ (Needs Pull)"
                details_msg="$branch_status"
            else
                synced="✅"
            fi
        fi
    fi
    
    # Print the table row
    printf "%-55s | %-15s | %-15s | %-20s\n" "$proj" "$loc" "$git" "$synced"
    
    # Print the specific uncommitted files or remote updates beneath the row
    if [[ -n "$details_msg" ]]; then
        # IFS= ensures leading spaces (like " M file.txt") aren't stripped by the read loop
        echo "$details_msg" | while IFS= read -r line; do
            printf "    └── %s\n" "$line"
        done
    fi
done

echo "---------------------------------------------------------------------------------------------------------------------"
echo "Total on GitHub:  ${#remote_repos[@]}"
echo "Total Local:      ${#local_dirs[@]}"