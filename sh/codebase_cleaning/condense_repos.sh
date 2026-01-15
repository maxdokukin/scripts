#!/bin/bash

INPUT_FILE=$1
OUTPUT_FILE="condensed_projects.csv"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Usage: $0 <input_csv>"
    exit 1
fi

tr -d '\r' < "$INPUT_FILE" | awk -F',' '
BEGIN { OFS = "," }
NR == 1 { next }
{
    repo = $1
    slug = $2

    gsub(/^[ \t\042]+|[ \t\042]+$/, "", repo)
    gsub(/^[ \t\042]+|[ \t\042]+$/, "", slug)

    if (slug != "") {
        if (!seen[slug]) {
            order[++count] = slug
            seen[slug] = 1
            repos[slug] = ""
        }

        r_low = tolower(repo)
        if (r_low != "n/a" && r_low != "") {
            if (repos[slug] == "") {
                repos[slug] = repo
            } else {
                if (index(repos[slug], repo) == 0) {
                    repos[slug] = repos[slug] ", " repo
                }
            }
        }
    }
}
END {
    print "Github Repo Condensed,Slug"
    for (i = 1; i <= count; i++) {
        s = order[i]
        printf "\"%s\",%s\n", repos[s], s
    }
}' > "$OUTPUT_FILE"

echo "Done. File created at: $OUTPUT_FILE"
