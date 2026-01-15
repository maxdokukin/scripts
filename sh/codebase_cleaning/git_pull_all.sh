#!/usr/bin/env zsh

# 1. Check for directory argument
if [[ -z "$1" ]]; then
    echo "Usage: $0 <path_to_repos_folder>"
    exit 1
fi

BASE_DIR=$1
TOTAL_REPOS=0

# 2. Check if the directory exists
if [[ ! -d "$BASE_DIR" ]]; then
    echo "Error: Directory '$BASE_DIR' not found."
    exit 1
fi

echo "Starting pull updates in: $BASE_DIR\n"

# 3. Iterate through every subdirectory
# The (/) suffix in Zsh ensures we only loop through directories
for repo in "$BASE_DIR"/*(/); do
    if [[ -d "$repo/.git" ]]; then
        ((TOTAL_REPOS++))
        REPO_NAME=$(basename "$repo")
        
        # Change into the repo directory
        cd "$repo" || continue

        # Run git pull and capture both stdout and stderr
        OUTPUT=$(git pull 2>&1)
        EXIT_CODE=$?

        # 4. Check status and print emojis
        if [[ $EXIT_CODE -ne 0 ]]; then
            echo "❌ Failed:      $REPO_NAME"
            # Optional: echo "$OUTPUT" | sed 's/^/  /' # Uncomment to see error details
        elif [[ "$OUTPUT" == *"Already up to date"* ]]; then
            echo "💤 No changes:  $REPO_NAME"
        else
            echo "✅ Success:     $REPO_NAME (Updated)"
        fi
        
        # Go back to the base directory
        cd - > /dev/null
    fi
done

echo "\n------------------------------------"
echo "🏁 Processed $TOTAL_REPOS repositories."
