#!/usr/bin/env zsh

# 1. Check if the destination path argument is provided
if [[ -z "$1" ]]; then
    echo "Usage: $0 <destination_path>"
    exit 1
fi

TARGET_DIR="$1"
mkdir -p "$TARGET_DIR"

# 2. Check if GitHub CLI is installed
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI ('gh') is not installed. Please install it first."
    exit 1
fi

echo "Fetching repository list from GitHub..."

# 3. Fetch list using HTTPS URLs to avoid SSH key issues
repos=$(gh repo list --limit 1000 --json name,url --template '{{range .}}{{.name}} {{.url}}{{"\n"}}{{end}}')

# 4. Loop through and clone
echo "$repos" | while read -r repo_name repo_url; do
    [[ -z "$repo_name" ]] && continue

    DEST_PATH="$TARGET_DIR/$repo_name"

    if [[ -d "$DEST_PATH" ]]; then
        echo "⏭️  Skipping '$repo_name': Already exists"
    else
        echo "📥 Cloning '$repo_name'..."
        git clone "$repo_url" "$DEST_PATH"
    fi
done

echo "\n✅ All repositories processed!"
