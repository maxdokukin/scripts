#!/bin/bash

# Input file from first argument
INPUT_FILE=$1

if [ ! -f "$INPUT_FILE" ]; then
    echo "Usage: ./gen_slugs.sh data.csv"
    exit 1
fi

echo "SET DEFINE OFF;"

# 1. sed 's/\r//g' removes Windows carriage returns
# 2. tail -n +2 skips the header
# 3. awk -F',' extracts column 2 and 3 specifically
sed 's/\r//g' "$INPUT_FILE" | tail -n +2 | awk -F',' '{print $2"|"$3}' | while IFS='|' read -r new_val old_val; do

    # Trim leading/trailing whitespace
    new_slug=$(echo "$new_val" | xargs)
    old_slug=$(echo "$old_val" | xargs)

    # Only generate if both values are present
    if [[ -n "$new_slug" && -n "$old_slug" ]]; then
        
        # Escape single quotes for Oracle (e.g., ' becomes '')
        # Important for GitHub URLs or titles with apostrophes
        sql_new=$(echo "$new_slug" | sed "s/'/''/g")
        sql_old=$(echo "$old_slug" | sed "s/'/''/g")

        echo "UPDATE PROJECTS_NEW SET NEW_SLUG = '$sql_new' WHERE OLD_SLUG = '$sql_old';"
    fi

done

echo "COMMIT;"
echo "EXIT;"
