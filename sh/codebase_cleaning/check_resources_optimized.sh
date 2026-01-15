#!/usr/bin/env zsh

if [[ -z "$1" ]]; then
    echo "Usage: $0 <path_to_repos_folder>"
    exit 1
fi

BASE_DIR=$1
TOTAL_UNOPTIMIZED=0

echo "🔍 Scanning for unoptimized files in static/media/...\n"

# Iterate through every subdirectory
for repo in "$BASE_DIR"/*(/); do
    if [[ -d "$repo/.git" ]]; then
        # specifically look for static/media within each repo
        TARGET_PATH="$repo/static/media"

        if [[ -d "$TARGET_PATH" ]]; then
            # Use find to look for files recursively in that folder
            # ! -name "*_optimized*" filters for files missing the suffix
            # -type f ensures we only look at files, not directories
            find "$TARGET_PATH" -type f ! -name "*_optimized*" | while read -r unoptimized_file; do
                # Ignore common system junk like .DS_Store
                if [[ $(basename "$unoptimized_file") != ".DS_Store" ]]; then
                    echo "🚩 $unoptimized_file"
                    ((TOTAL_UNOPTIMIZED++))
                fi
            done
        fi
    fi
done

echo "\n---------------------------------------"
echo "🏁 Found $TOTAL_UNOPTIMIZED unoptimized files."