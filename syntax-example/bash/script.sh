#!/usr/bin/env bash
# Disk usage summary. Run with: ./script.sh [path]

set -euo pipefail

readonly TARGET="${1:-.}"
readonly THRESHOLD_MB=10

if [[ ! -d "$TARGET" ]]; then
  echo "error: '$TARGET' is not a directory" >&2
  exit 1
fi

echo "Scanning $TARGET (threshold: ${THRESHOLD_MB}MB)..."
total=0
count=0

while IFS=$'\t' read -r size path; do
  mb=$((size / 1024 / 1024))
  if (( mb >= THRESHOLD_MB )); then
    printf "  %4d MB  %s\n" "$mb" "$path"
    count=$((count + 1))
  fi
  total=$((total + size))
done < <(find "$TARGET" -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -20)

total_mb=$((total / 1024 / 1024))
echo "---"
echo "large files: $count   total scanned: ${total_mb}MB"
