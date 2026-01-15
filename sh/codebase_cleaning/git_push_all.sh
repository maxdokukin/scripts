#!/bin/bash

# Usage: ./bulk_push.sh /path/to/repos "Your commit message"
BASE_DIR=$1
COMMIT_MSG=$2

if [[ -z "$BASE_DIR" || -z "$COMMIT_MSG" ]]; then
    echo "Usage: $0 [path_to_repos] [commit_message]"
    exit 1
fi

# Move to the target directory
cd "$BASE_DIR" || exit

echo "Starting bulk commit/push in: $(pwd)"
echo "------------------------------------------"

# Loop through every directory
for dir in */; do
    # Enter the directory
    cd "$dir" || continue
    
    repo_name="${dir%/}"

    # Check if this is actually a git repo
    if [[ -d ".git" ]]; then
        echo "[$repo_name]: Processing..."
        
        # 1. Add all changes
        git add .

        # 2. Commit (check if there is anything to commit first)
        if git commit -m "$COMMIT_MSG"; then
            echo "[$repo_name]: Committed successfully."
            
            # 3. Try to push to main, fallback to master if it fails
            echo "[$repo_name]: Attempting push to origin main..."
            if ! git push origin main; then
                echo "[$repo_name]: 'main' failed or doesn't exist. Trying 'master'..."
                git push origin master
            fi
        else
            echo "[$repo_name]: Nothing to commit (clean working tree)."
        fi
    else
        echo "[$repo_name]: Skipped (Not a Git repository)."
    fi

    # Go back to base directory
    cd ..
    echo "------------------------------------------"
done

echo "Bulk operation complete."
