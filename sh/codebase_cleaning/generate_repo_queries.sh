#!/bin/bash

# Usage: ./update_repos.sh path/to/data.csv
if [ -z "$1" ]; then
    echo "Usage: $0 path/to/data.csv"
    exit 1
fi

awk 'NR > 1 {
    # 1. Strip Windows carriage returns
    gsub(/\r/, "", $0);

    # 2. Split only at the FIRST comma
    split_pos = index($0, ",");
    if (split_pos > 0) {
        slug = substr($0, 1, split_pos - 1);
        repos = substr($0, split_pos + 1);

        # 3. Strip surrounding whitespace and double quotes
        gsub(/^[ \t\"]+|[ \t\"]+$/, "", slug);
        gsub(/^[ \t\"]+|[ \t\"]+$/, "", repos);

        # 4. Escape single quotes for SQL safety
        gsub(/\047/, "\047\047", slug);
        gsub(/\047/, "\047\047", repos);

        # 5. Print the UPDATE statement
        if (slug != "") {
            printf "UPDATE PROJECTS_NEW SET \"github_repos\" = \047%s\047 WHERE \"new_slug\" = \047%s\047;\n", repos, slug;
        }
    }
}' "$1"
