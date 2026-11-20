#!/usr/bin/env bash
# Print the total number of changed lines (added + deleted) in $BASE...$HEAD_REF.
# Usage: diff-size.sh <base-ref> [head-ref]
set -euo pipefail
BASE="${1:?usage: diff-size.sh <base-ref> [head-ref]}"
HEAD_REF="${2:-HEAD}"

# Three-dot: compare against the merge-base, matching the reviewers.
# --numstat emits "<added>\t<deleted>\t<path>"; binary files emit "-\t-".
git diff --numstat "${BASE}...${HEAD_REF}" \
  | awk '{ a = ($1 == "-" ? 0 : $1); d = ($2 == "-" ? 0 : $2); sum += a + d } END { print sum + 0 }'
