#!/usr/bin/env zsh

if [[ -z "$1" ]]; then
    echo "Usage: $0 <path_to_repos_folder>"
    exit 1
fi

TARGET_DIR=$1
TOTAL_PROCESSED=0

echo "🚀 Running .idea Cleanup & Gitignore Enforcement...\n"

for repo in "$TARGET_DIR"/*(/); do
    if [[ -d "$repo/.git" ]]; then
        ((TOTAL_PROCESSED++))
        REPO_NAME=$(basename "$repo")
        cd "$repo" || continue

        # 1. Enforce .gitignore for .idea/
        if [[ ! -f .gitignore ]]; then
            echo ".idea/" > .gitignore
        elif ! grep -qxF ".idea/" .gitignore; then
            # Ensure newline at end of file before appending
            [[ -s .gitignore && "$(tail -c 1 .gitignore | wc -l)" -eq 0 ]] && echo "" >> .gitignore
            echo ".idea/" >> .gitignore
        fi

        # 2. Stop tracking .idea/ folder (removes from Git index but keeps local files)
        # We redirect stderr to /dev/null in case .idea is already not tracked
        git rm -r --cached .idea/ 2>/dev/null

        # 3. Stage everything (the .gitignore change and the untracking)
        git add -A

        # 4. Check if there is actually anything to commit
        if ! git diff-index --quiet HEAD --; then
            git commit -m "chore: stop tracking .idea/ folder and update .gitignore" -q
            
            if git push -q 2>/dev/null; then
                echo "✅ $REPO_NAME: .idea removed from Git and ignored."
            else
                echo "⚠️  $REPO_NAME: Committed locally, but push failed (check remote permissions)."
            fi
        else
            echo "💤 $REPO_NAME: Already compliant."
        fi

        cd - > /dev/null
    fi
done

echo "\n---------------------------------------"
echo "🏁 Processed $TOTAL_PROCESSED repositories."