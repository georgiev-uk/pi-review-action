#!/usr/bin/env bash
# Post (or update in place) a sticky PR comment from a Markdown file.
# Idempotent: finds an existing comment carrying $MARKER and edits it,
# otherwise creates a new one. No-op-safe when not a PR (prints to stdout).
#
# Usage: post-comment.sh <body-file>
# Env:   GH_TOKEN / GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER
set -euo pipefail

BODY_FILE="${1:?usage: post-comment.sh <body-file>}"
MARKER="<!-- pi-review-action:sticky -->"

# Append the hidden marker so we can find this comment again next run.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat "$BODY_FILE" > "$TMP"
printf '\n\n%s\n' "$MARKER" >> "$TMP"

if [[ -z "${PR_NUMBER:-}" ]]; then
  echo "::notice::Not a pull request — skipping PR comment. Body:"
  cat "$TMP"
  exit 0
fi

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"

# Look for an existing sticky comment by this action.
EXISTING_ID="$(
  gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    --jq ".[] | select(.body | contains(\"${MARKER}\")) | .id" 2>/dev/null \
  | head -n1 || true
)"

if [[ -n "${EXISTING_ID}" ]]; then
  echo "Updating existing sticky comment ${EXISTING_ID}"
  gh api -X PATCH "repos/${REPO}/issues/comments/${EXISTING_ID}" \
    -F body=@"${TMP}" >/dev/null
else
  echo "Creating new sticky comment on PR #${PR_NUMBER}"
  gh api -X POST "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    -F body=@"${TMP}" >/dev/null
fi
