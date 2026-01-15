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
        if [[ -n $(git status --porcelain) ]]; then
            print -P "    %F{green}* Changes detected:%f Staging and committing..."
            git add .
            git commit -m 'sync'
        else
            print -P "    %F{white}* Status:%f No new changes to commit."
        fi
        print -P "    %F{green}* Syncing:%f Pushing to origin main..."
        git push origin main
        print -P "%F{blue}--------------------------------------------------%f"
    fi
  )
done
