#!/usr/bin/env zsh

# 1. Validation
if [[ -z "$1" ]]; then
    echo "Usage: $0 <path_to_repos_folder> [path_to_csv_file]"
    exit 1
fi

TARGET_DIR=$1
CSV_FILE=$2

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: Directory '$TARGET_DIR' not found."
    exit 1
fi

if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI ('gh') is not installed."
    exit 1
fi

echo "🔍 Fetching repository list from GitHub..."
remote_repos=($(gh repo list --limit 1000 --json name --template '{{range .}}{{.name}}{{"\n"}}{{end}}'))

echo "📁 Fetching local directories..."
local_dirs=($TARGET_DIR/*(/N:t))

csv_repos=()

if [[ -n "$CSV_FILE" ]]; then
    if [[ ! -f "$CSV_FILE" ]]; then
        echo "Error: CSV file '$CSV_FILE' not found."
        exit 1
    fi
    if ! command -v python3 &> /dev/null; then
        echo "Error: Python3 is required for robust CSV parsing but is not installed."
        exit 1
    fi

    echo "📄 Parsing CSV file and extracting slugs from links..."
    csv_repos=($(python3 -c "
import csv, sys

try:
    with open(sys.argv[1], newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        if 'github_repos' in reader.fieldnames:
            for row in reader:
                val = row['github_repos']
                if val:
                    for r in val.split(','):
                        clean_url = r.strip().rstrip('/')
                        if clean_url:
                            # Extract the last part of the URL (the slug)
                            slug = clean_url.split('/')[-1]
                            # Remove .git extension if present
                            if slug.endswith('.git'):
                                slug = slug[:-4]
                            if slug:
                                print(slug)
except Exception as e:
    print(f'Error reading CSV: {e}', file=sys.stderr)
" "$CSV_FILE"))
fi

# Map the lists using associative arrays
typeset -A in_git
typeset -A in_local
typeset -A in_csv

for repo in "${remote_repos[@]}"; do
    in_git[$repo]=1
done

for dir in "${local_dirs[@]}"; do
    in_local[$dir]=1
done

for repo in "${csv_repos[@]}"; do
    in_csv[$repo]=1
done

# Combine all arrays to get a unique list of all project slugs across all sources
all_keys=($(print -l "${remote_repos[@]}" "${local_dirs[@]}" "${csv_repos[@]}" | sort -u | awk 'NF'))

# Print the Report
if [[ -n "$CSV_FILE" ]]; then
    echo "\n📊 3-Way Verification Report"
    echo "-------------------------------------------------------------------------------------------------------------"
    printf "%-55s | %-15s | %-15s | %-15s\n" "proj-slug" "present_locally" "present_git" "present_csv"
    echo "--------------------------------------------------------|-----------------|-----------------|----------------"
else
    echo "\n📊 2-Way Verification Report"
    echo "-----------------------------------------------------------------------------------------------"
    printf "%-55s | %-15s | %-15s\n" "proj-slug" "present_locally" "present_git"
    echo "--------------------------------------------------------|-----------------|--------------------"
fi

for proj in "${all_keys[@]}"; do
    
    # Check local status
    if [[ -n "${in_local[$proj]}" ]]; then loc="✅"; else loc="❌"; fi
    
    # Check git status
    if [[ -n "${in_git[$proj]}" ]]; then git="✅"; else git="❌"; fi

    # Print rows dynamically
    if [[ -n "$CSV_FILE" ]]; then
        # Check csv status
        if [[ -n "${in_csv[$proj]}" ]]; then csv="✅"; else csv="❌"; fi
        printf "%-55s | %-15s | %-15s | %-15s\n" "$proj" "$loc" "$git" "$csv"
    else
        printf "%-55s | %-15s | %-15s\n" "$proj" "$loc" "$git"
    fi
done

if [[ -n "$CSV_FILE" ]]; then
    echo "-------------------------------------------------------------------------------------------------------------"
else
    echo "-----------------------------------------------------------------------------------------------"
fi

echo "Total on GitHub:  ${#remote_repos[@]}"
echo "Total Local:      ${#local_dirs[@]}"
if [[ -n "$CSV_FILE" ]]; then
    echo "Total in CSV:     ${#csv_repos[@]}"
fi