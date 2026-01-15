#!/usr/bin/env zsh

if [[ -z "$1" ]]; then
    echo "Usage: $0 <path_to_repos_folder>"
    exit 1
fi

TARGET_DIR=$1
TOTAL_PROCESSED=0

echo "🚀 Running Deep Cleanup & Gitignore Enforcement...\n"

for repo in "$TARGET_DIR"/*(/); do
    if [[ -d "$repo/.git" ]]; then
        ((TOTAL_PROCESSED++))
        REPO_NAME=$(basename "$repo")
        cd "$repo" || continue

        # 1. Enforce .gitignore first
        GITIGNORE_CHANGED=false
        if [[ ! -f .gitignore ]]; then
            echo ".DS_Store" > .gitignore
            GITIGNORE_CHANGED=true
        elif ! grep -qxF ".DS_Store" .gitignore; then
            # Ensure newline at end of file before appending
            [[ -s .gitignore && "$(tail -c 1 .gitignore | wc -l)" -eq 0 ]] && echo "" >> .gitignore
            echo ".DS_Store" >> .gitignore
            GITIGNORE_CHANGED=true
        fi

        # 2. Delete all .DS_Store files locally
        find . -name ".DS_Store" -delete 2>/dev/null

        # 3. Stage EVERYTHING (including the deletions and .gitignore)
        git add -A

        # 4. Check if there is actually anything to commit
        if ! git diff-index --quiet HEAD --; then
            git commit -m "chore: remove .DS_Store and enforce .gitignore" -q
            
            if git push -q 2>/dev/null; then
                echo "✅ $REPO_NAME: Cleaned, .gitignore updated, and pushed."
            else
                echo "⚠️  $REPO_NAME: Changes committed locally, but push failed."
            fi
        else
            echo "💤 $REPO_NAME: Already compliant."
        fi

        cd - > /dev/null
    fi
done

echo "\n---------------------------------------"
echo "🏁 Processed $TOTAL_PROCESSED repositories."
