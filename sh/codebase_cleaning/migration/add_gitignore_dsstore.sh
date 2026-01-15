#!/bin/zsh
root_dir="${1:-.}"
cd "$root_dir" || exit 1
for repo in **/.git(/N); do
  dir="${repo:h}"
  (
    cd "$dir" || continue
    remote_url=$(git remote get-url origin 2>/dev/null)
    if [[ "$remote_url" == *maxdokukin* ]]; then
        print -P "%F{cyan}==>%f %BRepo:%b %F{yellow}$dir%f"
        
        if ! grep -qxF ".DS_Store" .gitignore 2>/dev/null; then
            print -P "    %F{green}+%f Adding .DS_Store to .gitignore"
            echo ".DS_Store" >> .gitignore
        fi

        tracked_ds=$(git ls-files | grep ".DS_Store")
        if [[ -n "$tracked_ds" ]]; then
            print -P "    %F{red}-%f Removing committed .DS_Store files from index"
            echo "$tracked_ds" | xargs git rm --cached --quiet
        fi

        if [[ -n $(git status --porcelain) ]]; then
            print -P "    %F{green}*%f Committing .gitignore updates..."
            git add .gitignore
            git commit -m "chore: ignore and remove .DS_Store"
            print -P "    %F{green}*%f Pushing to origin main..."
            git push origin main
        else
            print -P "    %F{white}○%f No changes needed."
        fi
        print -P "%F{blue}--------------------------------------------------%f"
    fi
  )
done
