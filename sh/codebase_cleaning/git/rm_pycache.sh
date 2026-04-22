#!/usr/bin/env zsh

if [[ -z "$1" ]]; then
    echo "Usage: $0 <path_to_repos_folder>"
    exit 1
fi

TARGET_DIR=$1
TOTAL_PROCESSED=0

echo "🚀 Running __pycache__ Permanent Cleanup & Gitignore Enforcement...\n"

# Loop through directories in the target path
for repo in "$TARGET_DIR"/*(/); do
    if [[ -d "$repo/.git" ]]; then
        ((TOTAL_PROCESSED++))
        REPO_NAME=$(basename "$repo")
        cd "$repo" || continue

        # 1. Enforce .gitignore for __pycache__/
        if [[ ! -f .gitignore ]]; then
            echo "__pycache__/" > .gitignore
        elif ! grep -qxF "__pycache__/" .gitignore; then
            # Ensure newline at end of file before appending
            [[ -s .gitignore && "$(tail -c 1 .gitignore | wc -l)" -eq 0 ]] && echo "" >> .gitignore
            echo "__pycache__/" >> .gitignore
        fi

        # 2. Delete __pycache__ recursively from Git index and local disk
        # Remove from git tracking first (if they were accidentally committed)
        find . -type d -name "__pycache__" -exec git rm -r --cached --ignore-unmatch {} + 2>/dev/null
        
        # Remove completely from the local filesystem
        find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null

        # 3. Stage changes (the .gitignore update and staged deletions)
        git add .gitignore

        # 4. Commit and Push if changes exist
        if ! git diff-index --quiet HEAD --; then
            git commit -m "chore: permanently remove __pycache__ and update .gitignore" -q
            
            if git push -q 2>/dev/null; then
                echo "✅ $REPO_NAME: __pycache__ deleted recursively/remotely and added to .gitignore."
            else
                echo "⚠️  $REPO_NAME: Deleted locally/committed, but push failed."
            fi
        else
            echo "💤 $REPO_NAME: Already clean."
        fi

        cd - > /dev/null
    fi
done

echo "\n---------------------------------------"
echo "🏁 Processed $TOTAL_PROCESSED repositories."