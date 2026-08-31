#!/bin/bash

CSV_FILE="$1"

if [ -z "$CSV_FILE" ]; then
    echo "Usage: $0 /path/to/repos_to_archive.csv"
    exit 1
fi

if [ ! -f "$CSV_FILE" ]; then
    echo "ERROR: Cannot find $CSV_FILE"
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: GitHub CLI is not installed."
    exit 1
fi

awk -F',' '
NR == 1 {
    for (i = 1; i <= NF; i++) {
        gsub(/^[ \t"]+|[ \t"\r]+$/, "", $i)

        if ($i == "slug") {
            slug_col = i
        }

        if ($i == "archive") {
            archive_col = i
        }
    }

    if (!slug_col || !archive_col) {
        print "ERROR: Cannot find slug or archive column." > "/dev/stderr"
        exit 1
    }

    next
}

{
    slug = $slug_col
    archive = $archive_col

    gsub(/^[ \t"]+|[ \t"\r]+$/, "", slug)
    gsub(/^[ \t"]+|[ \t"\r]+$/, "", archive)

    if (archive == "1" && slug != "") {
        print slug
    }
}
' "$CSV_FILE" | while IFS= read -r repo; do
    echo "ARCHIVE: $repo"

    if gh repo archive "$repo" --yes; then
        echo "DONE: $repo"
    else
        echo "ERROR: Failed to archive $repo"
    fi
done