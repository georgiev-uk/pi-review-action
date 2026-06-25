#!/usr/bin/env bash
# Print the total number of changed lines (added + deleted) in $BASE...HEAD.
# Usage: diff-size.sh <base-ref>
set -euo pipefail
BASE="${1:?usage: diff-size.sh <base-ref>}"

# Three-dot: compare against the merge-base, matching the reviewers.
# --numstat emits "<added>\t<deleted>\t<path>"; binary files emit "-\t-".
git diff --numstat "${BASE}...HEAD" \
  | awk '{ a = ($1 == "-" ? 0 : $1); d = ($2 == "-" ? 0 : $2); sum += a + d } END { print sum + 0 }'
