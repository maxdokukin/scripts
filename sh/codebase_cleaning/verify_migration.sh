#!/usr/bin/env zsh

# 1. Configuration
ORIGIN_PARENT="/Users/max/from remote machine/Personal-Site-V2/static/images/projects"
DEST_PARENT="/Users/max/Palkan/data/src"
CSV_FILE="$1"

# Track processed old slugs to avoid redundant checks
typeset -A processed_old_slugs

if [[ -z "$CSV_FILE" || ! -f "$CSV_FILE" ]]; then
    echo "Usage: $0 <path_to_csv>"
    exit 1
fi

echo "🔍 Starting Deep-Audit Verification"
echo "📂 Origin:      $ORIGIN_PARENT"
echo "📂 Destination: $DEST_PARENT\n"

# 2. Extract Header and Find Column Indices
HEADER=$(head -n 1 "$CSV_FILE" | tr -d '\r')
COL_NEW=$(echo "$HEADER" | tr ',' '\n' | grep -nw "New Slug" | cut -d: -f1)
COL_OLD=$(echo "$HEADER" | tr ',' '\n' | grep -nw "Old Slug" | cut -d: -f1)

# 3. Counters for Final Report
TOTAL_ITEMS_CHECKED=0
TOTAL_SUCCESS=0
TOTAL_FAIL=0

# 4. Process the CSV
cat "$CSV_FILE" | tr -d '\r' | tail -n +2 | awk -F, -v cn="$COL_NEW" -v co="$COL_OLD" '{
    gsub(/"/, "", $cn); gsub(/"/, "", $co);
    print $cn "|" $co
}' | while read -r line; do

    NEW_SLUG=$(echo "$line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    OLD_SLUG=$(echo "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    [[ -z "$OLD_SLUG" ]] && continue
    if [[ -n "${processed_old_slugs[$OLD_SLUG]}" ]]; then
        continue
    fi
    processed_old_slugs[$OLD_SLUG]=1

    SOURCE_DIR="$ORIGIN_PARENT/$OLD_SLUG"
    TARGET_MEDIA_DIR="$DEST_PARENT/$NEW_SLUG/media"

    echo "----------------------------------------------------------"
    echo "🧐 VERIFYING PROJECT: $OLD_SLUG ➔ $NEW_SLUG"

    if [[ -d "$SOURCE_DIR" ]]; then
        # Find every file and folder in the origin
        (cd "$SOURCE_DIR" && find . -mindepth 1 -not -path '*/.*') | while read -r rel_path; do
            
            clean_rel_path="${rel_path#./}"
            SRC_ITEM="$SOURCE_DIR/$clean_rel_path"
            DST_ITEM="$TARGET_MEDIA_DIR/$clean_rel_path"
            
            ((TOTAL_ITEMS_CHECKED++))

            # ACTUAL VERIFICATION LOGIC
            if [[ -e "$DST_ITEM" ]]; then
                # Check if the type matches (don't want a file where a dir should be)
                if [[ -d "$SRC_ITEM" && -d "$DST_ITEM" ]] || [[ -f "$SRC_ITEM" && -f "$DST_ITEM" ]]; then
                    echo "  ✅ MATCH: $SRC_ITEM"
                    echo "            ➔ $DST_ITEM"
                    ((TOTAL_SUCCESS++))
                else
                    echo "  ⚠️  TYPE MISMATCH: $SRC_ITEM"
                    echo "            ➔ $DST_ITEM (Type differs!)"
                    ((TOTAL_FAIL++))
                fi
            else
                echo "  ❌ MISSING: $SRC_ITEM"
                echo "            ➔ EXPECTED AT: $DST_ITEM"
                ((TOTAL_FAIL++))
            fi
        done
    else
        echo "  🚫 SOURCE FOLDER MISSING: $SOURCE_DIR"
    fi
done

echo "\n=========================================================="
echo "📊 FINAL AUDIT SUMMARY"
echo "=========================================================="
echo "Total Items Checked: $TOTAL_ITEMS_CHECKED"
echo "Passed:              $TOTAL_SUCCESS"
echo "Failed:              $TOTAL_FAIL"
echo "=========================================================="

if [[ $TOTAL_FAIL -eq 0 && $TOTAL_ITEMS_CHECKED -gt 0 ]]; then
    echo "🎉 ALL FILES VERIFIED SUCCESSFULLY!"
else
    echo "🚨 VERIFICATION FAILED: Review the log above for ❌ or ⚠️ marks."
fi
