#!/bin/bash

# Usage: ./generate_sql.sh your_file.csv
FILE=$1

if [ ! -f "$FILE" ]; then
    echo "Error: File '$FILE' not found."
    exit 1
fi

# Process the CSV
# -F',' sets comma delimiter
# NR > 1 skips the header
# gsub replaces single quotes with double single quotes for the data values
awk -F',' 'NR > 1 && $1 != "" { 
    slug = $1
    gsub(/\047/, "\047\047", slug); 
    printf "INSERT INTO PROJECTS_NEW (\"new_slug\") SELECT \047%s\047 FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM PROJECTS_NEW WHERE \"new_slug\" = \047%s\047);\n", slug, slug 
}' "$FILE"
