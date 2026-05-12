#!/usr/bin/env bash
set -euo pipefail

dir="${1:-.}"
output="${2:-$dir/merged.pdf}"
outbase="$(basename "$output")"

files=()

while IFS= read -r file; do
  files+=("$file")
done < <(
  find "$dir" -maxdepth 1 -type f -iname "*.pdf" ! -name "$outbase" \
    | LC_ALL=C sort -f
)

if [ "${#files[@]}" -eq 0 ]; then
  echo "No PDF files found in: $dir"
  exit 1
fi

printf "Merging PDFs in this order:\n"
printf "%s\n" "${files[@]}"

qpdf --empty --pages "${files[@]}" -- "$output"

echo "Created: $output"
