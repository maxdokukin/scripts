#!/usr/bin/env zsh

# 1. Configuration
ORIGIN_PARENT="/Users/max/from remote machine/Personal-Site-V2/static/images/projects"
DEST_PARENT="/Users/max/Palkan/data/src"
CSV_FILE=""
DRY_RUN=false

# Deduplication: Track processed old slugs
typeset -A processed_old_slugs

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry) DRY_RUN=true ;;
        *) CSV_FILE=$arg ;;
    esac
done

if [[ -z "$CSV_FILE" || ! -f "$CSV_FILE" ]]; then
    echo "Usage: $0 <path_to_csv> [--dry]"
    exit 1
fi

echo "🚀 Starting Robust File-by-File Migration"
echo "📂 Origin Parent: $ORIGIN_PARENT"
echo "📂 Dest Parent:   $DEST_PARENT"
[[ "$DRY_RUN" == true ]] && echo "⚠️  DRY RUN MODE ENABLED\n"

# 2. Extract Header and Find Column Indices
HEADER=$(head -n 1 "$CSV_FILE" | tr -d '\r')
COL_NEW=$(echo "$HEADER" | tr ',' '\n' | grep -nw "New Slug" | cut -d: -f1)
COL_OLD=$(echo "$HEADER" | tr ',' '\n' | grep -nw "Old Slug" | cut -d: -f1)

if [[ -z "$COL_NEW" || -z "$COL_OLD" ]]; then
    echo "❌ Error: Could not find 'New Slug' or 'Old Slug' columns."
    exit 1
fi

# 3. Process the CSV
# tr -d '\r' handles Windows line endings
cat "$CSV_FILE" | tr -d '\r' | tail -n +2 | awk -F, -v cn="$COL_NEW" -v co="$COL_OLD" '{
    gsub(/"/, "", $cn); gsub(/"/, "", $co);
    print $cn "|" $co
}' | while read -r line; do

    NEW_SLUG=$(echo "$line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    OLD_SLUG=$(echo "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Skip if Old Slug is empty
    [[ -z "$OLD_SLUG" ]] && continue

    # Deduplication
    if [[ -n "${processed_old_slugs[$OLD_SLUG]}" ]]; then
        echo "⏭️  SKIPPING DUPLICATE OLD SLUG: $OLD_SLUG"
        continue
    fi
    processed_old_slugs[$OLD_SLUG]=1

    SOURCE_DIR="$ORIGIN_PARENT/$OLD_SLUG"
    TARGET_MEDIA_DIR="$DEST_PARENT/$NEW_SLUG/media"

    echo "\n----------------------------------------------------------"
    echo "📦 PROJECT: $OLD_SLUG ➔ $NEW_SLUG"

    if [[ -d "$SOURCE_DIR" ]]; then
        # 4. Iterate over every file/folder inside the source project
        # find . -mindepth 1 picks up everything inside the folder recursively
        (cd "$SOURCE_DIR" && find . -mindepth 1 -not -path '*/.*') | while read -r rel_path; do
            
            # Remove leading './' from find output
            clean_rel_path="${rel_path#./}"
            
            SRC_FILE="$SOURCE_DIR/$clean_rel_path"
            DST_FILE="$TARGET_MEDIA_DIR/$clean_rel_path"

            if [[ "$DRY_RUN" == true ]]; then
                echo "  🔍 [DRY] $SRC_FILE ➔ $DST_FILE"
            else
                # If it's a directory, create it
                if [[ -d "$SRC_FILE" ]]; then
                    mkdir -p "$DST_FILE"
                    echo "  📁 CREATED DIR: $DST_FILE"
                else
                    # If it's a file, ensure parent dir exists then copy
                    mkdir -p "$(dirname "$DST_FILE")"
                    if cp "$SRC_FILE" "$DST_FILE"; then
                        echo "  📄 COPIED FILE: $SRC_FILE ➔ $DST_FILE"
                    else
                        echo "  ❌ FAILED: $SRC_FILE"
                    fi
                fi
            fi
        done
    else
        echo "  ⚠️  SOURCE NOT FOUND: $SOURCE_DIR"
    fi
done

echo "\n✨ Migration Complete."
