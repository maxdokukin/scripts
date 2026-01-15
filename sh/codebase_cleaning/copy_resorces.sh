#!/bin/bash

# Usage: ./sync_folders.sh /path/to/origin /path/to/destination
SRC=$1
DEST=$2

if [[ -z "$SRC" || -z "$DEST" ]]; then
    echo "Usage: $0 [origin_path] [destination_path]"
    exit 1
fi

# Ensure paths don't have trailing slashes for the logic below
SRC="${SRC%/}"
DEST="${DEST%/}"

echo "Syncing contents from $SRC to $DEST..."

# Loop through every directory in the origin path
for dir in "$SRC"/*/; do
    # Get the folder name (slug)
    slug=$(basename "$dir")

    # Check if that slug exists in the destination
    if [[ -d "$DEST/$slug" ]]; then
        echo "Merging contents: $slug -> $DEST/$slug/"
        
        # rsync -av: archive mode + verbose
        # The trailing slash on the source "$dir" is key: 
        # it tells rsync to copy the CONTENTS, not the folder itself.
        rsync -av "$dir" "$DEST/$slug/"
    else
        echo "Skipping: $slug (not found in destination)"
    fi
done

echo "Finished."
