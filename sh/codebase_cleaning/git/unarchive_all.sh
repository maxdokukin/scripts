#!/usr/bin/env zsh

if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI ('gh') is not installed."
    exit 1
fi

echo "🔍 Fetching archived repositories..."

# 1. Get the list of archived repos
archived_repos=($(gh repo list --limit 1000 --archived --json nameWithOwner --template '{{range .}}{{.nameWithOwner}}{{"\n"}}{{end}}'))

if [[ ${#archived_repos[@]} -eq 0 ]]; then
    echo "✨ No archived repositories found."
    exit 0
fi

echo "Attempting to unarchive ${#archived_repos[@]} repos via API...\n"

for repo in "${archived_repos[@]}"; do
    echo -n "🔓 Unarchiving '$repo'..."
    
    # 2. Use the GitHub API to set archived to false
    # We send a PATCH request to /repos/{owner}/{repo}
    echo '{"archived": false}' | gh api -X PATCH "repos/$repo" --input - &>/dev/null
    
    if [[ $? -eq 0 ]]; then
        echo " ✅"
    else
        echo " ❌ (Failed - check permissions or if repo name is correct)"
    fi
done

echo "\n---------------------------------------"
echo "🏁 Process Complete"
