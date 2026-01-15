#!/usr/bin/env zsh

# 1. Check if a file path was provided
if [[ -z "$1" ]]; then
    echo "Usage: $0 <path_to_csv_file>"
    exit 1
fi

CSV_FILE="$1"

# 2. Check if the file exists
if [[ ! -f "$CSV_FILE" ]]; then
    echo "Error: File '$CSV_FILE' not found."
    exit 1
fi

echo "Reading $CSV_FILE..."

# 3. Find the column index for "New Slug"
# This looks at the first line, splits by comma, and finds the position of "New Slug"
COL_INDEX=$(head -n 1 "$CSV_FILE" | tr ',' '\n' | grep -nw "New Slug" | cut -d: -f1)

if [[ -z "$COL_INDEX" ]]; then
    echo "Error: Column 'New Slug' not found in the CSV header."
    exit 1
fi

echo "Found 'New Slug' at column index: $COL_INDEX"

# 4. Extract unique slugs and create directories
# - awk: extracts the specific column
# - tail: skips the header line
# - sort -u: ensures we only have unique names
# - xargs: runs mkdir for each name
cat "$CSV_FILE" | \
    awk -F, -v col="$COL_INDEX" '{gsub(/"/, "", $col); print $col}' | \
    tail -n +2 | \
    sort -u | \
    while read -r dir_name; do
        if [[ -n "$dir_name" ]]; then
            mkdir -p "$dir_name"
            echo "📁 Created: $dir_name"
        fi
    done

echo "\n✅ Done! All unique directories created in $(pwd)"
