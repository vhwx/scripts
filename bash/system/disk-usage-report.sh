#!/usr/bin/env bash
#
# Script:       disk-usage-report.sh
# Description:  Prints a sorted disk usage report for the given directory (defaults to cwd).
# Usage:        ./disk-usage-report.sh [directory]
# Requirements: du, sort (standard on macOS/Linux)
# Author:       example
# Date:         2026-09-15

set -euo pipefail

target_dir="${1:-.}"

if [[ ! -d "$target_dir" ]]; then
  echo "Error: '$target_dir' is not a directory" >&2
  exit 1
fi

echo "Disk usage report for: $target_dir"
du -h -d 1 "$target_dir" 2>/dev/null | sort -rh
