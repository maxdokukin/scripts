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
# We use --limit 1000 to ensure we get all repos
remote_repos=($(gh repo list --limit 1000 --json name --template '{{range .}}{{.name}}{{"\n"}}{{end}}'))

# 3. Get list of local directories
# (N:t) is Zsh magic: N (nullglob), :t (tail/basename only)
local_dirs=($TARGET_DIR/*(/N:t))

# 4. Compare the lists
missing_repos=()
cloned_count=0

for repo in "${remote_repos[@]}"; do
    if (( ${local_dirs[(Ie)$repo]} )); then
        ((cloned_count++))
    else
        missing_repos+=("$repo")
    fi
done

# 5. Print the Report
echo "---------------------------------------"
echo "📊 Verification Report"
echo "---------------------------------------"
echo "Total on GitHub:  ${#remote_repos[@]}"
echo "Total Local:      ${#local_dirs[@]}"
echo "Already Cloned:   ✅ $cloned_count"

if [[ ${#missing_repos[@]} -eq 0 ]]; then
    echo "Status:           🎉 Everything is synced!"
else
    echo "Status:           ⚠️  ${#missing_repos[@]} repos are missing locally."
    echo "\nMissing Repositories:"
    for missing in "${missing_repos[@]}"; do
        echo "  - $missing"
    done
fi
echo "---------------------------------------"
