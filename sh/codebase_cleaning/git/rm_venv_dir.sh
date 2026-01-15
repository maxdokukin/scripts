#!/usr/bin/env zsh

if [[ -z "$1" ]]; then
    echo "Usage: $0 <path_to_repos_folder>"
    exit 1
fi

TARGET_DIR=$1
TOTAL_PROCESSED=0

echo "🚀 Running .venv Permanent Cleanup & Gitignore Enforcement...\n"

# Loop through directories in the target path
for repo in "$TARGET_DIR"/*(/); do
    if [[ -d "$repo/.git" ]]; then
        ((TOTAL_PROCESSED++))
        REPO_NAME=$(basename "$repo")
        cd "$repo" || continue

        # 1. Enforce .gitignore for .venv/
        if [[ ! -f .gitignore ]]; then
            echo ".venv/" > .gitignore
        elif ! grep -qxF ".venv/" .gitignore; then
            # Ensure newline at end of file before appending
            [[ -s .gitignore && "$(tail -c 1 .gitignore | wc -l)" -eq 0 ]] && echo "" >> .gitignore
            echo ".venv/" >> .gitignore
        fi

        # 2. Delete .venv locally and from Git index
        # This removes the folder from your disk AND stages the deletion for GitHub
        if [[ -d ".venv" ]]; then
            rm -rf .venv/
            git rm -r .venv/ --ignore-unmatch 2>/dev/null
        fi

        # 3. Stage changes (including the .gitignore update)
        git add .gitignore

        # 4. Commit and Push if changes exist
        if ! git diff-index --quiet HEAD --; then
            git commit -m "chore: permanently remove .venv and update .gitignore" -q
            
            if git push -q 2>/dev/null; then
                echo "✅ $REPO_NAME: .venv deleted locally/remotely and added to .gitignore."
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