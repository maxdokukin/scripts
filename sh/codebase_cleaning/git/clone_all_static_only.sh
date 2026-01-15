#!/bin/bash

# Usage: ./clone_static_status.sh /path/to/target_dir
TARGET_DIR=$1
USERNAME="maxdokukin"
CONCURRENCY=8

if [[ -z "$TARGET_DIR" ]]; then
    echo "Usage: $0 [target_directory]"
    exit 1
fi

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR" || exit

cat > _worker.sh << 'EOF'
#!/bin/bash
REPO_NAME=$1
USERNAME="maxdokukin"

if git clone --depth 1 "https://github.com/$USERNAME/$REPO_NAME.git" > /dev/null 2>&1; then
    cd "$REPO_NAME" || exit
    rm -rf .git

    if [[ -d "static" ]]; then
        # CASE A: Root static found.
        find . -mindepth 1 -maxdepth 1 ! -name 'static' -exec rm -rf {} + 2>/dev/null
        echo "[✓ ROOT STATIC] $REPO_NAME"
    else
        # CASE B: No root static. Cleanup non-static files.
        find . -type f -not -path "*/static/*" -delete 2>/dev/null
        find . -depth -type d -empty -not -name "static" -delete 2>/dev/null
        
        # Check if any files remain to determine status
        if [[ -n $(find . -type f -print -quit) ]]; then
            echo "[✓ DEEP STATIC] $REPO_NAME"
        else
            echo "[! EMPTY]       $REPO_NAME"
        fi
    fi
else
    echo "[X FAILED]      $REPO_NAME"
fi
EOF

chmod +x _worker.sh

echo "Processing repos..."

gh repo list "$USERNAME" --limit 4000 --json name -q '.[].name' | \
xargs -n 1 -P "$CONCURRENCY" ./_worker.sh

rm _worker.sh

echo "Done."